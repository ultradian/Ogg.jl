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

If the buffers are `nothing` than this packet does not carry its own memory with
it.
"""
struct OggPage
    rawpage::RawOggPage
    headerbuf::Union{Vector{UInt8}, Nothing}
    bodybuf::Union{Vector{UInt8}, Nothing}
end

function OggPage(page::RawOggPage; copy=true)
    if !copy
        OggPage(page, nothing, nothing)
    else
        # create new buffers and copy the data
        headerbuf = Vector{UInt8}(undef, page.header_len)
        unsafe_copyto!(pointer(headerbuf), page.header, page.header_len)
        bodybuf = Vector{UInt8}(undef, page.body_len)
        unsafe_copyto!(pointer(bodybuf), page.body, page.body_len)
        newpage = RawOggPage(pointer(headerbuf), page.header_len,
                             pointer(bodybuf), page.body_len)
        OggPage(newpage, headerbuf, bodybuf)
    end
end

serial(page::OggPage) = ogg_page_serialno(page.rawpage)
bos(page::OggPage) = ogg_page_bos(page.rawpage)
eos(page::OggPage) = ogg_page_eos(page.rawpage)
granulepos(page::OggPage) = ogg_page_granulepos(page.rawpage)

const MAX_PAGE_SIZE = 65307

function Base.deepcopy(page::OggPage)
    OggPage(page.rawpage, copy=true)
end

"""
    Vector(page::OggPage)

Returns a copy of the raw `OggPage` data as a `Vector{UInt8}`.
"""
function Base.Vector(page::OggPage)
    if page.headerbuf !== nothing && page.bodybuf !== nothing
        vcat(page.headerbuf, page.bodybuf)
    else
        # this assumes that the `ogg_sync_state` holding this data is still
        # alive. Make sure it's `GC.@preserve`ed!
        header_arr = unsafe_wrap(Array, page.rawpage.header, page.rawpage.header_len)
        body_arr = unsafe_wrap(Array, page.rawpage.body, page.rawpage.body_len)
        vcat(header_arr, body_arr)
    end
end

function Base.show(io::IO, x::OggPage)
    write(io, "OggPage ID: $(serial(x)), body: $(x.rawpage.body_len) bytes")
end

function Base.:(==)(x::OggPage, y::OggPage)
    # we'll just compare the data inside, we don't care where it's located
    return x.rawpage == y.rawpage
end


"""
Normally within libogg the `ogg_packet` struct doesn't carry its own memory, it
points to data within the `ogg_stream_state` struct. Here we create our own
`OggPacket` type that can hold data, and use `RawOggPacket` as the type that
maps to the libogg `ogg_packet` struct. Remember to use `GC.@preserve` to make
sure this object is retained during any `ccall`s that use the underlying
`RawOggPacket` struct.

If the buffer is `nothing` than this packet does not carry its own memory with
it.
"""
struct OggPacket
    rawpacket::RawOggPacket
    buf::Union{Vector{UInt8}, Nothing}
end

function OggPacket(packet::RawOggPacket; copy=true)
    if copy
        buf = Vector{UInt8}(undef, packet.bytes)
        unsafe_copyto!(pointer(buf), packet.packet, packet.bytes)
        newpacket = RawOggPacket(pointer(buf), packet.bytes,
                                 packet.b_o_s, packet.e_o_s,
                                 packet.granulepos, packet.packetno)
        OggPacket(newpacket, buf)
    else
        OggPacket(packet, nothing)
    end
end

# give a new OggPacket that carries all its own memory
function Base.deepcopy(packet::OggPacket)
    OggPacket(packet.rawpacket; copy=true)
end

bos(pkt::OggPacket) = pkt.rawpacket.b_o_s == 1
eos(pkt::OggPacket) = pkt.rawpacket.e_o_s == 1
Base.length(pkt::OggPacket) = pkt.rawpacket.bytes
granulepos(pkt::OggPacket) = pkt.rawpacket.granulepos
packetno(pkt::OggPacket) = pkt.rawpacket.packetno

function Base.show(io::IO, x::OggPacket)
    bosflag = bos(x) ? "BOS" : ""
    eosflag = eos(x) ? "EOS" : ""
    flagsep = (bos(x) && eos(x)) ? "|" : ""
    flagend = (bos(x) || eos(x)) ? ", " : ""
    flags = string(bosflag, flagsep, eosflag, flagend)
    write(io,"OggPacket <$flags$(length(x)) bytes, granule: $(granulepos(x)), seq: $(packetno(x))>")
end

# define a more verbose multi-line display
function Base.show(io::IO, ::MIME"text/plain", x::OggPacket)
    write(io, """OggPacket
                   sequence number: $(packetno(x))
                   flags: BOS($(bos(x))) EOS($(eos(x)))
                   granulepos: $(granulepos(x))
                   length: $(length(x)) bytes
              """)
end

"""
    Vector(packet::OggPacket)

Returns the raw `OggPacket` data as a `Vector{UInt8}`. Does not copy the data.
"""
function Base.Vector(packet::OggPacket)
    if packet.buf !== nothing
        packet.buf
    else
        unsafe_wrap(Array, packet.rawpacket.packet, length(packet))
    end
end

function Base.:(==)(x::OggPacket, y::OggPacket)
    # we'll just compare the data inside, we don't care where it's located
    return x.rawpacket == y.rawpacket
end

# currently frankensteined from the old PageSink, not tested, just a place
# to put that code in case it's useful
"""
    OggLogicalStream(container, serialnum)

Represents a logical bitstream within a physical bitstream.
"""
# parametric to break circular type definition. T should be an OggDecoder
mutable struct OggLogicalStream{T}
    container::T
    serial::SerialNum
    streamstate::OggStreamState

    OggLogicalStream{T}(container, serialnum) where T =
        new(container, serialnum, OggStreamState(serialnum))
end

OggLogicalStream(container, serialnum) =
    OggLogicalStream{OggDecoder}(container, serialnum)

"""
    clearbuffers(str::OggLogicalStream)

Reset the internal buffers of the logical stream. This is called internally
whenever the stream is seeked, so that the next `readpacket` won't get stale
data.
"""
function clearbuffers(str::OggLogicalStream)
    str.streamstate = ogg_stream_reset_serialno(str.streamstate, str.serial)
end

function Base.show(io::IO, str::OggLogicalStream)
    print(io, "OggLogicalStream with serial $(str.serial)")
end

# the type parameter is not actually used parametrically, so don't display it
function Base.show(io::IO, ::Type{<:OggLogicalStream})
    print(io, "OggLogicalStream")
end

function Base.close(stream::OggLogicalStream)
    stream.container.logstreams[stream.serial] = nothing
    stream.streamstate = ogg_stream_clear(stream.streamstate)

    nothing
end

# aliased for convenience. For each logical stream we need to keep track of
# two things - the OggLogicalStream which handles the page->packet decoding, and
# a buffer of any pages that are queued up for a read.
const LogStreamDict = Dict{SerialNum,
                           Union{Tuple{OggLogicalStream, Vector{OggPage}},
                                 Nothing}}

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
    # logstreams keeps a buffer for each opened logical stream. If the decoder
    # encounters pages for one stream while looking for those of another, it
    # will save those pages in their respective buffer (if that stream has been
    # opened). a value of `nothing` means the logical stream exists but is not
    # opened
    logstreams::LogStreamDict
    pagebuf::Vector{OggPage}
end

function OggDecoder(io::IO; own=false)
    sync = OggSyncState()

    dec = OggDecoder(io, own, sync, LogStreamDict(), OggPage[])
    # scan through all the pages with the BOS flag (they should all be at the
    # beginning) so we know what serials we're dealing with. We add them to the
    # pagebuf `Vector` so they're still available to users
    while true
        page = _readpage(dec)
        page === nothing && break
        push!(dec.pagebuf, page)
        bos(page) || break
        dec.logstreams[serial(page)] = nothing
    end

    # we end up with one extra page (the first one after the BOS pages) in
    # the buffer, but it gets read out correctly later

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
    dec.syncstate = ogg_sync_clear(dec.syncstate)

    nothing
end

# TODO: add tests for seeking functions
Base.position(dec::OggDecoder) = position(dec.io)
function Base.seek(dec::OggDecoder, pos)
    seek(dec.io, pos)
    clearbuffers(dec)
    dec
end
function Base.skip(dec::OggDecoder, delta)
    skip(dec.io, delta)
    clearbuffers(dec)
    dec
end
function Base.seekstart(dec::OggDecoder)
    seekstart(dec.io)
    clearbuffers(dec)
    dec
end
function Base.seekend(dec::OggDecoder)
    seekend(dec.io)
    clearbuffers(dec)
    dec
end

# TODO: I wonder if this should just be what we export as `seek`, rather than
# giving the (less useful) ability to seek to a given byte location.
"""
    seekgranule(logstr::OggLogicalStream, target)

Seek the Ogg stream to prepare to read data at the given granulepos. More
precisely, after this call the stream will be near `target`, and guaranteed to
be able to read the first packet in the stream containing the granulepos
`target`. The stream will generally end up within a few pages or packets of the
target, whichever is larger.

For sample-accurate seeking call `sync` on the logical stream, which will return
the granulepos of the last decoded data. The next packet read will generally
start at the next granulepos. For example:

```julia
target = 382712
len = 48000

# open the ogg decoder
OggDecoder(path) do dec
    # open the logical stream to read packets from
    open(dec, streams(dec)[1]) do logstr
        seekgranule(logstr, target)
        next_gp = sync(logstr) + 1
        # create a `OpusDecoder` (from the Opus.jl package) to decode the
        # packets into audio samples. It takes a packet iterator and reads from
        # it as needed.
        OpusDecoder(eachpacket(logstr)) do auddec
            # read and discard as many samples as we need to get to our target
            read(auddec, target - next_gp)

            # now we can start reading the desired samples
            read(auddec, len)
        end
    end
end
```
"""
function seekgranule(logstr::OggLogicalStream, target)
    # This search process is somewhat tricky. For a given position, seeking the
    # underlying stream with `seek(dec, pos); readpage(dec)` will give us the
    # first page that starts at or after the given position:
    #
    # -----+-----+-----+-----
    #  ... | p1  | p2  | ...
    # -----+-----+-----+-----
    #     ^ ^
    #     | `- : returns p2
    #     `--- : returns p1
    #
    # Pages get the granulepos of the last packet that ends on that page. If no
    # packets end on that page, it gets a granulepos of -1. For our purposes we
    # consider these to be continuations of the previous page, so we skip them.
    #
    #  page         +-----------+ +---------+ +---------+ +--------------+
    #  granulepos----------> 10 | |      20 | |      -1 | |           40 |
    #               |           | |         | |         | |              |
    #  packet       | +-----+ +-----+ +-----------------------+ +------+ |
    #  granulepos------> 10 | |  20 | |                    30 | |   40 | |
    #               | +-----+ +-----+ +-----------------------+ +------+ |
    #               |           | |         | |         | | ^            |
    #               +-----------+ +---------+ +---------+ +-|------------+
    #                       ^             ^                 |
    #                minpos |             | maxpos          `-- seek target (29)
    #                       `-----+-------'
    #                             `-- binary search result


    # We start our binary search with the seek endpoints at the beginning and
    # end of the file, and we check the point halfway between them. We compare
    # the granule position at our seek point to the one we're looking for, and
    # update either our minimum or maximum endpoint to tighten our bound. So if
    # we're searching for a granule position that's somewhere in `p2`, the seek
    # point we'll converge to is the beginning of `p1` (because that's the point
    # where `readpage(dec)` will return `p2`).

    # given that each seek in the binary search will require scanning to find
    # the next page boundary and parsing a page, we might as well just switch to
    # linear search once we are likely to be within a page. 4K is a typical page
    # size, and could otherwise take another 16 seeks to get to zero in.

    # Some more info here:
    # https://wiki.xiph.org/GranulePosAndSeeking
    # though some of the complexities are left "as an exercise to the reader"

    # also here:
    # http://web.archive.org/web/20031201054855/http://www.xiph.org/archives/theora-dev/200209/0040.html

    dec = logstr.container
    serialnum = logstr.serial

    # TODO: to properly handle chained files we'd want to initialize these to
    # the chain boundaries
    minpos = 0
    seekend(dec)
    maxpos = position(dec)

    # we do some copy-free page-reading in this loop, so we need to make sure
    # that the stream object sticks around as long as we're accessing those
    # pages.
    GC.@preserve logstr while maxpos - minpos > 4096
        # we could be more clever about picking a point to seek to and reduce
        # the number of seeks necessary. Currently we always go halfway
        pos = minpos + (maxpos - minpos) ÷ 2
        seek(dec, pos)
        page = readpage(dec, copy=false)
        # when searching we want to skip any pages that don't end a packet. They
        # don't have a valid granulepos. Also skip any pages from other logical
        # streams
        # TODO: if we end up in a different chain here then it could keep
        # reading until it gets to the end of the file. Probably want to be
        # smarter about that
        while page !== nothing && position(dec) <= maxpos &&
              (serial(page) != serialnum || granulepos(page) == -1)
            page = readpage(dec, copy=false)
        end
        if page === nothing || position(dec) > maxpos
            # no valid pages start after this seek point
            maxpos = pos
            continue
        end
        if granulepos(page) >= target
            maxpos = pos-1
        else
            minpos = pos
        end
    end

    # At this point we know that if we start reading from `minpos` we will hit a
    # page that finishes a packet that is earlier than the one we're looking
    # for. Note that we might not have enough of this preceeding packet to
    # decode it. This means two useful things:
    #  1. we'll get a known granulepos that's before what we're looking for, so
    #     we can synchronize for sample-accuracy
    #  2. The packet we're looking for starts somewhere after this, so we
    #     definitely have all the data we need to decode it.
    seek(dec, minpos)

    dec
end

"""
Gets the last page of the given ogg stream, or `nothing` if there are no pages
"""
function lastpage(dec::OggDecoder, copy=true)
    seekend(dec)
    # seek back a bit, but not before the beginning of the file
    seek(dec, max(position(dec)-MAX_PAGE_SIZE, 0))

    page = nothing
    next = readpage(dec, copy=false)
    while next !== nothing
        page = next
        next = readpage(dec, copy=false)
    end

    GC.@preserve dec if page === nothing
        nothing
    else
        copy ? deepcopy(page) : page
    end
end

"""
    clearbuffers(dec::OggDecoder)

Clear all the internal buffers of the decoder and any opened
`OggLogicalStreams`. The `OggDecoder` type buffers pages internally, e.g. when a
page for a specific logical stream is requested but other pages are found along
the way. These pages are buffered so they can be provided later. When the stream
is seeked to a different location we need to clear out these buffers.
"""
function clearbuffers(dec::OggDecoder)
    dec.pagebuf = OggPage[]
    for (serial, strdata) in dec.logstreams
        if strdata !== nothing
            (str, pagebuf) = strdata
            clearbuffers(str)
            dec.logstreams[serial] = (str, OggPage[])
        end
    end
    dec.syncstate = ogg_sync_reset(dec.syncstate)

    nothing
end

"""
    open(dec::OggDecoder, serialno::Integer)
    open(f::Function, dec::OggDecoder, serialno::Integer)

Open a logical stream identified with the given serial number. Returns an
`OggLogicalStream` object that you can read pages and packets from. The logical
stream should be closed with `close(stream)`, or you can use `do` syntax to
ensure that it is closed automatically.
"""
function Base.open(dec::OggDecoder, serialno::Integer)
    if serialno ∉ keys(dec.logstreams)
        throw(ArgumentError("Serial $serialno not found. Valid serials for this stream are $(keys(dec.logstreams))"))
    end
    if dec.logstreams[serialno] !== nothing
        # this is probably over-cautious, but it's not clear what should happen
        # if there are multiple handles to a given logical stream that are open
        # simultaneously
        throw(ErrorException("Opening a logical stream more than once is not supported"))
    end
    str = OggLogicalStream(dec, serialno)

    # register the stream with the container. This is needed so that the
    # container can handle resetting all the streams when it is seeked.
    dec.logstreams[serialno] = (str, OggPage[])

    str
end

function Base.open(fn::Function, dec::OggDecoder, serialno::Integer)
    stream = open(dec, serialno)
    try
        fn(stream)
    finally
        close(stream)
    end
end

function Base.show(io::IO, dec::OggDecoder)
    strs = streams(dec)
    plural = length(strs) == 1 ? "" : "s"
    println(io, "OggDecoder($(dec.io)")
    print(io,   "  $(length(strs)) logical stream$plural with serial$plural:")
    for str in strs
        print(io, "\n    $str")
    end
end

streams(dec::OggDecoder) = collect(keys(dec.logstreams))

"""
    eachpage(dec::OggDecoder; copy=true)
    eachpage(dec::OggLogicalStream; copy=true)

Returns an iterator you can use to get the pages from an ogg physical bitstream.
If you pass the `copy=false` keyword argument then the page will point to data
within the decoder buffer, and is only valid until the next page is provided.
"""
eachpage(dec; copy=true) = OggPageIterator(dec, copy)

struct OggPageIterator{T}
    dec::T
    copy::Bool
end

Base.IteratorSize(::Type{OggPageIterator{T}}) where T = Base.SizeUnknown()
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

If `copy` is `false` then the OggPage will contain a pointer to data within the
`dec`. This avoids the need to copy the data but the data will be
overwritten on the next `readpage` call. Also if the `dec` is garbage-collected
then the data will be invalid. Use `copy=false` with caution.

Note that if there are any `OggLogicalStream`s open, they may have consumed
pages, so this method will provide the next page that hasn't been read by a
logical stream.
"""
function readpage(dec::OggDecoder; copy=true)
    # first see if we have any pages in the queue
    isempty(dec.pagebuf) || return popfirst!(dec.pagebuf)

    _readpage(dec, copy)
end

"""
Internal page read function that ignores the julia-side BOS page queue. Returns
`nothing` if we're at the end of the stream.
"""
function _readpage(dec::OggDecoder, copy::Bool=true)
    # first check to see if there's already a page ready
    page, dec.syncstate = ogg_sync_pageout(dec.syncstate)
    GC.@preserve dec begin
        page === nothing || return OggPage(page; copy=copy)
    end

    # no pages ready, so read more data until we get one
    while !eof(dec.io)
        buffer, dec.syncstate = ogg_sync_buffer(dec.syncstate, READ_CHUNK_SIZE)
        bytes_read = readbytes!(dec.io, buffer, READ_CHUNK_SIZE)
        dec.syncstate = ogg_sync_wrote(dec.syncstate, bytes_read)
        page, dec.syncstate = ogg_sync_pageout(dec.syncstate)

        GC.@preserve dec begin
            page === nothing || return OggPage(page; copy=copy)
        end
    end

    # we hit EOF without reading a page
    return nothing
end

"""
    readpage(dec::OggDecoder, serialnum::SerialNum; copy=true)

Reads a page from the given logical stream within the decoder. If the decoder
encounters pages for other opened logical streams it will buffer them. This
method will usually not be called from user code - use
`readpage(::OggLogicalStream)` instead.

Returns `nothing` if there are no more pages in the given logical stream.
"""
function readpage(dec::OggDecoder, serialnum::SerialNum; copy=true)
    if !(serialnum in keys(dec.logstreams))
        throw(ErrorException("OggDecoder error - stream $serialnum not found"))
    end
    if dec.logstreams[serialnum] === nothing
        throw(ErrorException("OggDecoder error - stream must be opened before reading"))
    end
    # first see if we have any pages in the queue
    _, pagebuf = dec.logstreams[serialnum]
    isempty(pagebuf) || return popfirst!(pagebuf)
    page = readpage(dec, copy=false)
    GC.@preserve dec while page !== nothing && serial(page) != serialnum
        # this is not the page we're looking for. buffer it if we have an open
        # logical stream for it
        pageserial = serial(page)
        if pageserial in keys(dec.logstreams) && dec.logstreams[pageserial] !== nothing
            _, buf = dec.logstreams[pageserial]
            # we're storing the page in the queue, so we need to copy the data
            # even if the user didn't request their page to be copied
            push!(buf, deepcopy(page))
        end
        page = readpage(dec, copy=false)
    end

    if page === nothing
        nothing
    else
        GC.@preserve dec begin
            copy ? deepcopy(page) : page
        end
    end
end

"""
    readpage(stream::OggLogicalStream; copy=true)

Read a page from the given logical stream. Returns `nothing` if there are no
more pages.
"""
readpage(stream::OggLogicalStream; copy=true) =
    readpage(stream.container, stream.serial; copy=copy)

"""
    readpacket(stream::OggLogicalStream; copy=true)

Read a packet from the given logical stream. If there is not enough data
buffered this will cause a read to the underlying stream, which will yield the
task.

Returns the new packet (an `OggPacket`), or `nothing` if there are no more
packets in the stream.

CAUTION:

If `copy` is `false` then the OggPage will contain a pointer to data within the
`stream`. This avoids the need to copy the data but the data will be overwritten
on the next `readpage` call. Also if the `stream` is closed then the data will
be invalid. Use `copy=false` with caution, and make sure to keep `stream` open
until the packet data is copied. It is also recommended to use `GC.@preserve` to
maintain an active reference to `stream` for as long as the packet data is
needed.
"""
function readpacket(stream::OggLogicalStream; copy=true)
    packet, stream.streamstate = ogg_stream_packetout(stream.streamstate)
    while packet === nothing
        # don't need to copy because we're immediately pushing into the
        # streamstate, which copies into its own buffer
        page = readpage(stream, copy=false)
        # if the page is nothing than the logical stream is over
        page === nothing && return nothing
        # we need to preserve `stream` here because it also references the
        # ogg_sync_state struct that contains the page data
        GC.@preserve stream begin
            stream.streamstate = ogg_stream_pagein(stream.streamstate, page.rawpage)
        end
        packet, stream.streamstate = ogg_stream_packetout(stream.streamstate)
    end

    GC.@preserve stream begin
        OggPacket(packet, copy=copy)
    end
end

"""
    sync(stream::OggLogicalStream)

Synchronizes the stream to the next known granulepos and returns it. The
returned value will be the granulepos of the end of the last decoded packet, so
the next packet returned by `readpacket(stream)` will have data starting at the
next one.

Returns `nothing` if we're at the end of the stream.
"""
function sync(stream::OggLogicalStream)
    while true
        packet, stream.streamstate = ogg_stream_packetout(stream.streamstate)
        # if there's already a packet ready and it has a granulepos, we're done
        if packet !== nothing && granulepos(packet) != -1
            return GC.@preserve stream granulepos(packet)
        end
        packet === nothing && break
    end
    # read pages until we get one with a granulepos, meaning that a packet ends
    # on that page
    local page
    while true
        page = readpage(stream, copy=false)
        page === nothing && return nothing
        GC.@preserve stream begin
            stream.streamstate = ogg_stream_pagein(stream.streamstate, page.rawpage)
            granulepos(page) != -1 && break
        end
    end

    # now read all available packets given the pages we've read in. The last
    # packet we read will have the granulepos of the last page we read in. It's
    # also possible that we don't read in any packets because the packet that
    # ends on this page started on some earlier page before we started reading.
    # That's OK too, though, we still know that the data in the next readable
    # packet will start right after the page granulepos.

    while true
        packet, stream.streamstate = ogg_stream_packetout(stream.streamstate)
        packet === nothing && break
    end

    # any access to `page` needs to make sure that the stream data doesn't get
    # pulled out from underneath us
    GC.@preserve stream granulepos(page)
end

"""
    eachpacket(dec::OggLogicalStream; copy=true)

Returns an iterator you can use to get the packets from an ogg physical bitstream.
If you pass the `copy=false` keyword argument then the packet will point to data
within the decoder buffer, and is only valid until the next packet is provided.
"""
eachpacket(dec::OggLogicalStream; copy=true) = OggPacketIterator(dec, copy)

struct OggPacketIterator
    dec::OggLogicalStream
    copy::Bool
end

Base.IteratorSize(::Type{OggPacketIterator}) = Base.SizeUnknown()
Base.eltype(::OggPacketIterator) = OggPacket

function Base.iterate(i::OggPacketIterator, state=nothing)
    nextpacket = readpacket(i.dec, copy=i.copy)
    nextpacket === nothing && return nothing

    (nextpacket, nothing)
end

# """
# File goes in, packets come out
# """
# function decode_all_packets(dec::OggDecoder, enc_io::IO)
#     # Now, decode all packets for these pages
#     for serial in keys(dec.streams)
#         packet = ogg_stream_packetout(dec, serial)
#         while packet != nothing
#             # This packet will soon go away, and we're unsafe_wrap'ing its data
#             # into an arry, so we make an explicit copy of that wrapped array,
#             # then push that into `dec.packets[]`
#             packet_data = copy(unsafe_wrap(Array, packet.packet, packet.bytes))
#             push!(dec.packets[serial], packet_data)
#
#             # If this was the last packet in this stream, delete the stream from
#             # the list of streams.  `ogg_stream_packetout()` should return `nothing`
#             # after this.  Note that if a stream just doesn't have more information
#             # available, it's possible for `ogg_stream_packetout()` to return `nothing`
#             # even without `packet.e_o_s == 1` being true.  In that case, we can come
#             # back through `decode_all_packets()` a second time to get more packets
#             # from the streams that have not ended.
#             if packet.e_o_s == 1
#                 delete!(dec.streams, serial)
#             end
#
#             packet = ogg_stream_packetout(dec, serial)
#         end
#     end
# end
#
# function load(fio::IO; chunk_size=4096)
#     dec = OggDecoder()
#     decode_all_pages(dec, fio; chunk_size=chunk_size)
#     decode_all_packets(dec, fio)
#     return dec.packets
# end

# function load(file_path::Union{File{format"OGG"},AbstractString}; chunk_size=4096)
#     open(file_path) do fio
#         return load(fio)
#     end
# end
