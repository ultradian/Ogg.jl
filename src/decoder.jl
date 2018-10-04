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

Closing the decoder will also close any open logical streams.
"""
mutable struct OggDecoder{T<:IO}
    io::T
    ownstream::Bool
    sync_state::OggSyncState
    streams::Dict{Clong,OggStreamState}
end

function OggDecoder(io::IO; own=false)
    sync = OggSyncState()
    dec = OggDecoder(io, own, sync, Dict{Clong,OggStreamState}())
    return dec
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
    ogg_sync_clear(dec.sync)

    nothing
end

"""
    eachpage(dec::OggDecoder; copy=true)

Returns an iterator you can use to get the pages from an ogg physical bitstream.
If you pass the `copy=false` keyword argument then the page will point to data
within the decoder buffer, and is only valid until the next page is provided.

## Examples

```julia
```
"""
# TODO: add copy kwarg
eachpage(dec::OggDecoder) = OggPageIterator(dec)

struct OggPageIterator
    dec::OggDecoder
end

# we want to keep one page ahead of the iterator, so that we know ahead of time
# if we're done
# Base.start(iter::OggPageIterator) = readpage(iter.dec)
# Base.next(iter::OggPageIterator, next) = return get(next), readpage(iter.dec)
# Base.done(iter::OggPageIterator, next) = isnull(next)

# we'll try to read from the underlying stream in chunks this size
const READ_CHUNK_SIZE = 4096

"""
    readpage(dec::OggDecoder)::Nullable{OggPage}

Read the next page from the ogg decoder. Returns the nullable-wrapped page,
which is null if there are no more pages. This function will block the task if
it needs to wait to read from the underlying IO stream.
"""
function readpage(dec::OggDecoder)
    # first check to see if there's already a page ready
    page = ogg_sync_pageout(dec)
    if !isnull(page)
        return page
    end
    # no pages ready, so read more data until we get one
    while !eof(dec.io)
        buffer = ogg_sync_buffer(dec, READ_CHUNK_SIZE)
        bytes_read = readbytes!(dec.io, buffer, READ_CHUNK_SIZE)
        ogg_sync_wrote(dec, bytes_read)
        page = ogg_sync_pageout(dec)
        if !isnull(page)
            return page
        end
    end
    # we hit EOF without reading a page
    return Nullable{OggPage}()
end

# currently frankensteined from the old PageSink, not tested, just a place
# to put that code in case it's useful
struct OggLogicalStream
    state::OggStreamState
    serial::Cint
    container::OggDecoder

    OggLogicalStream(container, serial) = stream = new(OggStreamState(), serial, container)
end

function Base.open(stream::OggLogicalStream)
    open_logical_stream(stream.container, stream)
end

# note it's a little weird that we pass the stream as an argument to the given
# function, given that the context already has a reference. Seems worth it for
# consistency with other open... functions though. The thing that makes
# OggLogicalStream weird is that it starts in a closed state.
function Base.open(fn::Function, stream::OggLogicalStream)
    open(stream)
    try
        fn(stream)
    finally
        close(stream)
    end
end

function Base.close(stream::OggLogicalStream)
    close_logical_stream(stream.container, stream)
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
