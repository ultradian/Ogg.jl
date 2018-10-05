"""
The OggPage struct encapsulates the data for an Ogg page.

Ogg pages are the fundamental unit of framing and interleave in an ogg
bitstream. They are made up of packet segments of 255 bytes each. There can be
as many as 255 packet segments per page, for a maximum page size of a little
under 64 kB. This is not a practical limitation as the segments can be joined
across page boundaries allowing packets of arbitrary size. In practice many
applications will not completely fill all pages because they flush the
accumulated packets periodically order to bound latency more tightly.

Normally within libogg the `ogg_page` struct doesn't carry its own memory, it
points to data within the `ogg_sync_state` struct. Here we create our own
`OggPage` type that can hold data, and use `RawOggPage` as the type that maps to
the libogg `ogg_page` struct. Remember to use `GC.@preserve` to make sure this
object is retained during any `ccall`s that use the underlying `RawOggPage`
struct.
"""
struct OggPage
    page::RawOggPage
    headerbuf::Union{Vector{UInt8}, Nothing}
    bodybuf::Union{Vector{UInt8}, Nothing}
end

function OggPage(page::RawOggPage; copy=true)
    if !copy
        OggPage(page, nothing, nothing)
    else
        deepcopy(OggPage(page, copy=false))
    end
end

serial(page::OggPage) = ogg_page_serialno(page.page)
bos(page::OggPage) = ogg_page_bos(page.page)
eos(page::OggPage) = ogg_page_eos(page.page)

function Base.deepcopy(page::OggPage)
    headerbuf = Vector{UInt8}(undef, page.page.header_len)
    unsafe_copyto!(pointer(headerbuf), page.page.header, page.page.header_len)
    bodybuf = Vector{UInt8}(undef, page.page.body_len)
    unsafe_copyto!(pointer(bodybuf), page.page.body, page.page.body_len)

    page = RawOggPage(pointer(headerbuf), page.page.header_len,
                    pointer(bodybuf), page.page.body_len)
    OggPage(page, headerbuf, bodybuf)
end

function show(io::IO, x::OggPage)
    write(io, "OggPage ID: $(serial(x)), body: $(x.page.body_len) bytes")
end

# currently frankensteined from the old PageSink, not tested, just a place
# to put that code in case it's useful
"""
    OggLogicalStream(container, serialnum)

Represents a logical bitstream within a physical bitstream.
"""
# TODO: confirm we need multiple states rather than an `opened` Bool
# parametric to break circular type definition. T should be an OggDecoder
struct OggLogicalStream{T}
    state::Symbol # :init, :opened, :reading, :closed
    streamstate::OggStreamState
    serial::SerialNum
    container::T

    OggLogicalStream{T}(container, serialnum) where T =
        new(:init, OggStreamState(serialnum), serialnum, container)
end

OggLogicalStream(container::T, serialnum) where T =
    OggLogicalStream{T}(container, serialnum)

function Base.open(stream::OggLogicalStream)
    stream.state = :opened
end

function Base.close(stream::OggLogicalStream)
    stream.state = :closed
    ogg_stream_clear(Ref(stream.streamstate))
end

"""
    OggDecoder(io::IO, own=false)
    OggDecoder(fname::AbstractString)
    OggDecoder(fn::Function, io::IO; own=false)
    OggDecoder(fn::Function, fname::AbstractString)

Decodes an Ogg file given by a stream or filename. If opened with a stream, the
`own` argument determines whether the decoder will handle closing the
underlying stream when it is closed. You can also use `do` syntax (with either
a stream or a filename) to to run a block of code, and the decoder will handle
closing itself afterwards. Otherwise the user is responsible for calling `close`
on the decoder when you are finished with it.

Note that opening an `OggDecoder` will automatically consume the initial `BOS`
page(s) in the physical stream, so that it can build a list of logical streams.

Closing the decoder will also close any open logical streams.
"""
mutable struct OggDecoder{T<:IO}
    io::T
    ownstream::Bool
    syncstate::OggSyncState
    logstreams::Dict{SerialNum, OggLogicalStream}
    pagebuf::Vector{OggPage}
end

function OggDecoder(io::IO; own=false)
    sync = OggSyncState()

    dec = OggDecoder(io, own, sync, Dict{SerialNum, OggLogicalStream}(), OggPage[])
    # scan through all the pages with the BOS flag (they should all be at the
    # beginning) so we know what serials we're dealing with. We add them to the
    # pagebuf so they're still available to users
    page = _readpage(dec)
    page !== nothing && push!(dec.pagebuf, page)
    while page !== nothing && bos(page)
        ser = serial(page)
        dec.logstreams[ser] = OggLogicalStream(dec, ser)
        page = _readpage(dec)
        page !== nothing && push!(dec.pagebuf, page)
    end

    dec
end

OggDecoder(fname::AbstractString) = OggDecoder(open(fname); own=true)

# handle do syntax. this works whether io is a stream or file
function OggDecoder(f::Function, io; kwargs...)
    dec = OggDecoder(io; kwargs...)
    try
        f(dec)
    finally
        close(dec)
    end
end

function Base.close(dec::OggDecoder)
    # for stream in streams(dec)
    #     isopen(stream) && close(stream)
    # end
    if dec.ownstream
        close(dec.io)
    end
    ogg_sync_clear(Ref(dec.syncstate))

    nothing
end

streams(dec::OggDecoder) = collect(keys(dec.logstreams))

"""
    eachpage(dec::OggDecoder; copy=true)

Returns an iterator you can use to get the pages from an ogg physical bitstream.
If you pass the `copy=false` keyword argument then the page will point to data
within the decoder buffer, and is only valid until the next page is provided.
"""
eachpage(dec::OggDecoder; copy=true) = OggPageIterator(dec, copy)

struct OggPageIterator
    dec::OggDecoder
    copy::Bool
end

Base.IteratorSize(::Type{OggPageIterator}) = Base.SizeUnknown()
Base.eltype(::OggPageIterator) = OggPage

function Base.iterate(i::OggPageIterator, state=nothing)
    nextpage = readpage(i.dec, copy=i.copy)
    nextpage === nothing && return nothing

    (nextpage, nothing)
end

# we'll try to read from the underlying stream in chunks this size
const READ_CHUNK_SIZE = 4096

"""
    readpage(dec::OggDecoder; copy=true)::Union{OggPage, Nothing}

Read the next page from the ogg decoder. Returns the page, or `nothing` if there
are no more pages (all logical streams have ended or the physical stream has hit
EOF) This function will block the task if it needs to wait to read from the
underlying IO stream.

If `copy` is `false` than the data the `OggPage` points to
"""
function readpage(dec::OggDecoder; copy=true)
    # first see if we have any pages in the queue
    !isempty(dec.pagebuf) && return popfirst!(dec.pagebuf)

    _readpage(dec, copy)
end

"""
Internal page read function that ignores the julia-side page queue
"""
function _readpage(dec::OggDecoder, copy::Bool=true)
    # first check to see if there's already a page ready
    syncref = Ref(dec.syncstate)
    page = ogg_sync_pageout(syncref)
    page !== nothing && return OggPage(page; copy=copy)

    # no pages ready, so read more data until we get one
    while !eof(dec.io)
        buffer = ogg_sync_buffer(syncref, READ_CHUNK_SIZE)
        bytes_read = readbytes!(dec.io, buffer, READ_CHUNK_SIZE)
        ogg_sync_wrote(syncref, bytes_read)
        page = ogg_sync_pageout(syncref)

        page !== nothing && return OggPage(page; copy=copy)
    end

    # we hit EOF without reading a page
    return nothing
end


"""
    readpage(stream::OggLogicalStream)

Read a page from the given logical stream.
"""
readpage(stream::OggLogicalStream) = readpage(stream.container, stream.serial)

"""
    readpacket(stream::OggLogicalStream)

Read a packet from the given logical stream.
"""
function readpacket(stream::OggLogicalStream)
    # TODO: check here if we actually need to read a new page
        nextpage = readpage(stream)
        ogg_stream_pagein(sink.streamstate, nextpage)
    # TODO: read out the next packet
end

function decode_all_pages(dec::OggDecoder, enc_io::IO; chunk_size::Integer = 4096)
    # Load data in until we have a page to sync out
    while !eof(enc_io)
        page = ogg_sync_pageout(dec)
        while page != nothing
            ogg_stream_pagein(dec, page)
            page = ogg_sync_pageout(dec)
        end

        # Load in up to `chunk_size` of data, unless the stream closes before that
        buffer = ogg_sync_buffer(dec, chunk_size)
        bytes_read = readbytes!(enc_io, buffer, chunk_size)
        ogg_sync_wrote(dec, bytes_read)
    end

    # Do our last pageouts to get the last pages
    page = ogg_sync_pageout(dec)
    while page != nothing
        ogg_stream_pagein(dec, page)
        page = ogg_sync_pageout(dec)
    end
end

"""
File goes in, packets come out
"""
function decode_all_packets(dec::OggDecoder, enc_io::IO)
    # Now, decode all packets for these pages
    for serial in keys(dec.streams)
        packet = ogg_stream_packetout(dec, serial)
        while packet != nothing
            # This packet will soon go away, and we're unsafe_wrap'ing its data
            # into an arry, so we make an explicit copy of that wrapped array,
            # then push that into `dec.packets[]`
            packet_data = copy(unsafe_wrap(Array, packet.packet, packet.bytes))
            push!(dec.packets[serial], packet_data)

            # If this was the last packet in this stream, delete the stream from
            # the list of streams.  `ogg_stream_packetout()` should return `nothing`
            # after this.  Note that if a stream just doesn't have more information
            # available, it's possible for `ogg_stream_packetout()` to return `nothing`
            # even without `packet.e_o_s == 1` being true.  In that case, we can come
            # back through `decode_all_packets()` a second time to get more packets
            # from the streams that have not ended.
            if packet.e_o_s == 1
                delete!(dec.streams, serial)
            end

            packet = ogg_stream_packetout(dec, serial)
        end
    end
end

function load(fio::IO; chunk_size=4096)
    dec = OggDecoder()
    decode_all_pages(dec, fio; chunk_size=chunk_size)
    decode_all_packets(dec, fio)
    return dec.packets
end

# function load(file_path::Union{File{format"OGG"},AbstractString}; chunk_size=4096)
#     open(file_path) do fio
#         return load(fio)
#     end
# end
