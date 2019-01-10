# this file has the low-level libogg types and wrappers for ccall functions. It
# provides some thin convenience wrappers but matches the same basic API as
# libogg

# When the libogg function modifies a variable by reference, the wrapper will
# take the (immutable) value as an argument and return the updated value. This
# way the caller doesn't have to worry about getting the reference juggling
# correct.

# docstrings are mostly copied from https://xiph.org/ogg/doc/libogg/reference.html

# These types all shadow libogg datatypes, hence they are all immutable

"""
The ogg_sync_state struct tracks the synchronization of the current page.

It is used during decoding to track the status of data as it is read in,
synchronized, verified, and parsed into pages belonging to the various logical
bistreams in the current physical bitstream link.
"""
struct OggSyncState
    # Pointer to buffered stream data
    data::Ptr{UInt8}
    # Current allocated size of the stream buffer held in *data
    storage::Cint
    # The number of valid bytes currently held in *data; functions as the buffer head pointer
    fill::Cint
    # The number of bytes at the head of *data that have already been returned as pages;
    # functions as the buffer tail pointer
    returned::Cint

    # Synchronization state flag; nonzero if sync has not yet been attained or has been lost
    unsynced::Cint
    # If synced, the number of bytes used by the synced page's header
    headerbytes::Cint
    # If synced, the number of bytes used by the synced page's body
    bodybytes::Cint

    function OggSyncState()
        syncstate = Ref(new())
        status = ccall((:ogg_sync_init, libogg), Cint, (Ref{OggSyncState},), syncstate)
        if status != 0
            error("ogg_sync_init() failed: This should never happen")
        end

        syncstate[]
    end
end

"""
This function is used to free the internal storage of an ogg_sync_state struct
and resets the struct to the initial state. To free the entire struct,
ogg_sync_destroy should be used instead. In situations where the struct needs to
be reset but the internal storage does not need to be freed, ogg_sync_reset
should be used.

Returns the reset OggSyncState object.
"""
function ogg_sync_clear(sync::OggSyncState)
    syncref = Ref(sync)
    ccall((:ogg_sync_clear,libogg), Cint, (Ref{OggSyncState},), syncref)

    syncref[]
end

"""
This function is used to reset the internal counters of the ogg_sync_state
struct to initial values.

It is a good idea to call this before seeking within a bitstream.

Returns the reset OggSyncState object.
"""
function ogg_sync_reset(sync::OggSyncState)
    syncref = Ref(sync)
    ccall((:ogg_sync_reset, libogg), Cint, (Ref{OggSyncState},), syncref)

    syncref[]
end

struct RawOggPage
    # Pointer to the page header for this page
    header::Ptr{UInt8}
    # Length of the page header in bytes
    header_len::Clong
    # Pointer to the data for this page
    body::Ptr{UInt8}
    # Length of the body data in bytes
    body_len::Clong
end

# zero-constructor
RawOggPage() = RawOggPage(C_NULL, 0, C_NULL, 0)

function Base.:(==)(x::RawOggPage, y::RawOggPage)
    x.header_len == y.header_len &&
    x.body_len == y.body_len &&
    unsafe_wrap(Array, x.header, x.header_len) == unsafe_wrap(Array, y.header, y.header_len) &&
    unsafe_wrap(Array, x.body, x.body_len) == unsafe_wrap(Array, y.body, y.body_len)
end

"""
The OggStreamState struct tracks the current encode/decode state of the current
logical bitstream, i.e. converting elementary stream pages into logical stream
packets.
"""
struct OggStreamState
    # Pointer to data from packet bodies
    body_data::Ptr{UInt8}
    # Storage allocated for bodies in bytes (filled or unfilled)
    body_storage::Clong
    # Amount of storage filled with stored packet bodies
    body_fill::Clong
    # Number of elements returned from storage
    body_returned::Clong

    # String of lacing values for the packet segments within the current page
    # Each value is a byte, indicating packet segment length
    lacing_vals::Ptr{Cint}
    # Pointer to the lacing values for the packet segments within the current page
    granule_vals::Ptr{Int64}
    # Total amount of storage (in bytes) allocated for storing lacing values
    lacing_storage::Clong
    # Fill marker for the current vs. total allocated storage of lacing values for the page
    lacing_fill::Clong
    # Lacing value for current packet segment
    lacing_packet::Clong
    # Number of lacing values returned from lacing_storage
    lacing_returned::Clong

    # Temporary storage for page header during encode process, while the header is being created
    header::NTuple{282,UInt8}
    # Fill marker for header storage allocation. Used during the header creation process
    header_fill::Cint

    # Marker set when the last packet of the logical bitstream has been buffered
    e_o_s::Cint
    # Marker set after we have written the first page in the logical bitstream
    b_o_s::Cint
    # Serial number of this logical bitstream
    serialno::Clong
    # Number of the current page within the stream
    pageno::Clong
    # Number of the current packet
    packetno::Int64
    # Exact position of decoding/encoding process
    granulepos::Int64

    function OggStreamState(serialno::Integer)
        streamstate = Ref(new())
        status = ccall((:ogg_stream_init,libogg), Cint,
                       (Ref{OggStreamState}, Cint), streamstate, serialno)
        if status != 0
            error("ogg_stream_init() failed with status $status")
        end

        streamstate[]
    end
end

function Base.show(io::IO, streamstate::OggStreamState)
    println(io, "OggStreamState(")
    for field in [
            :body_data, :body_storage, :body_fill, :body_returned, :lacing_vals,
            :granule_vals, :lacing_storage, :lacing_fill, :lacing_packet,
            :lacing_returned, :header, :header_fill, :e_o_s, :b_o_s, :serialno,
            :pageno, :packetno, :granulepos]
        if field == :header
            print(io, "  header=$(typeof(streamstate.header))(...)")
        else
            print(io, "  $field=$(getfield(streamstate, field))")
        end
        field == :granulepos || println(io, ",")
    end
    println(io, ")")
end

"""
This function clears and frees the internal memory used by the ogg_stream_state
struct, but does not free the structure itself. It is safe to call
ogg_stream_clear on the same structure more than once.
"""
function ogg_stream_clear(stream::OggStreamState)
    streamref = Ref(stream)
    ccall((:ogg_stream_clear,libogg), Cint, (Ref{OggStreamState},), streamref)

    @debug "ogg_stream_clear() called"

    streamref[]
end

"""
This function reinitializes the values in the ogg_stream_state, just like
ogg_stream_reset(). Additionally, it sets the stream serial number to the given
value.
"""
function ogg_stream_reset_serialno(stream::OggStreamState, serialno::Integer)
    streamref = Ref(stream)
    status = ccall((:ogg_stream_reset_serialno,libogg), Cint,
                   (Ref{OggStreamState}, Cint), streamref, serialno)
    if status != 0
        error("ogg_stream_reset_serialno() failed with status $status")
    end

    @debug "ogg_stream_reset_serialno called with serial $serialno"

    streamref[]
end

"""
This function is used to check the error or readiness condition of an
ogg_stream_state structure.

It is safe practice to ignore unrecoverable errors (such as an internal error
caused by a malloc() failure) returned by ogg stream synchronization calls.
Should an internal error occur, the ogg_stream_state structure will be cleared
(equivalent to a call to ogg_stream_clear) and subsequent calls using this
ogg_stream_state will be noops. Error detection is then handled via a single
call to ogg_stream_check at the end of the operational block.
"""
function ogg_stream_check(stream::OggStreamState)
    streamref = Ref(stream)
    ccall((:ogg_stream_check, libogg), Cint, (Ref{OggStreamState},), streamref)
end

struct RawOggPacket
    # Pointer to the packet's data. This is treated as an opaque type by the ogg layer
    packet::Ptr{UInt8}
    # Indicates the size of the packet data in bytes. Packets can be of arbitrary size
    bytes::Clong
    # Flag indicating whether this packet begins a logical bitstream
    # 1 indicates this is the first packet, 0 indicates any other position in the stream
    b_o_s::Clong
    # Flag indicating whether this packet ends a bitstream
    # 1 indicates the last packet, 0 indicates any other position in the stream
    e_o_s::Clong

    # A number indicating the position of this packet in the decoded data
    # This is the last sample, frame or other unit of information ('granule')
    # that can be completely decoded from this packet
    granulepos::Int64
    # Sequential number of this packet in the ogg bitstream
    packetno::Int64
end
# zero-constructor
RawOggPacket() = RawOggPacket(C_NULL, 0, 0, 0, 0, 0)

function Base.:(==)(x::RawOggPacket, y::RawOggPacket)
    x.bytes == y.bytes &&
    x.b_o_s == y.b_o_s &&
    x.granulepos == y.granulepos &&
    x.packetno == y.packetno &&
    unsafe_wrap(Array, x.data, x.bytes) == unsafe_wrap(Array, y.data, y.bytes)
end

"""
    ogg_sync_buffer(dec::OggSyncState, size)

Request a buffer for writing new raw data into from the physical bitstream.

Buffer space which has already been returned is cleared, and the buffer is
extended as necessary by the `size` (in bytes) plus some additional bytes.
Within the current implementation, an extra 4096 bytes are allocated, but
applications should not rely on this additional buffer space.

The buffer exposed by this function is empty internal storage from the
`OggSyncState` struct, beginning at the fill mark within the struct.

After copying data into this buffer you should call `ogg_sync_wrote` to tell the
`OggSyncState` struct how many bytes were actually written, and update the
fill mark.

Returns an `Array` wrapping the provided buffer and the new `OggSyncState`
value.

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_buffer.html)
"""
function ogg_sync_buffer(syncstate::OggSyncState, size)
    syncref = Ref(syncstate)
    buffer = ccall((:ogg_sync_buffer,libogg), Ptr{UInt8},
                   (Ref{OggSyncState}, Clong),
                   syncref, size)
    if buffer == C_NULL
        error("ogg_sync_buffer() failed: returned buffer NULL")
    end
    @debug "ogg_sync_buffer ready to receive $size bytes"

    # note that the Array doesn't own the data, it will not be freed by Julia
    # when the array goes out of scope (which is what we want, because libogg
    # owns the data)
    unsafe_wrap(Array, buffer, size), syncref[]
end

"""
    ogg_sync_wrote(dec::OggSyncState, size)

Tell the OggSyncState struct how many bytes we wrote into the buffer.

Note that the argument is a reference to the `OggSyncState` object, which is
immutable to Julia but will be updated by libogg.

The general proceedure is to request a pointer into an internal ogg_sync_state
buffer by calling ogg_sync_buffer(). The buffer is then filled up to the
requested size with new input, and ogg_sync_wrote() is called to advance the
fill pointer by however much data was actually written.

Returns the new `OggSyncState` value.
"""
function ogg_sync_wrote(syncstate::OggSyncState, size)
    syncref = Ref(syncstate)
    status = ccall((:ogg_sync_wrote, libogg), Cint,
                   (Ref{OggSyncState}, Clong),
                   syncref, size)
    if status != 0
        error("ogg_sync_wrote() failed: error code $status")
    end

    @debug "ogg_sync_wrote notified with $size bytes"
    syncref[]
end

"""
    ogg_sync_pageout(syncstate::OggSyncState)

Takes the data stored in the buffer of the OggSyncState and inserts them into an
ogg_page. Note that the payload data in the page is not copied, so the memory
the RawOggPage points to is still contained within the OggSyncState struct.

Caution: This function should be called before reading into the buffer to ensure
that data does not remain in the OggSyncState struct. Failing to do so may
result in a memory leak. See the example code below for details.

Returns a new RawOggPage if it was available, or nothing if not (more data is
needed). Also returns the updated `OggSyncState` value.

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_pageout.html)
"""
function ogg_sync_pageout(syncstate::OggSyncState, isretry=false)
    syncref = Ref(syncstate)
    page = Ref(RawOggPage())
    status = ccall((:ogg_sync_pageout,libogg), Cint,
                   (Ref{OggSyncState}, Ref{RawOggPage}),
                   syncref, page)
    if status == 1
        @debug "ogg_sync_pageout: $(page[])"
        page[], syncref[]
    elseif status == 0
        @debug "ogg_sync_pageout: nothing"
        nothing, syncref[]
    elseif status == -1 && !isretry
        @debug "ogg_sync_pageout unsynced, retrying..."
        ogg_sync_pageout(syncref[], true)
    else
        @warn "Got unexpected return value from ogg_sync_pageout: $status"
        nothing, syncref[]
    end
end

"""
    ogg_page_serialno(page::RawOggPage)

Returns the serial number of the given page
"""
function ogg_page_serialno(page::RawOggPage)
    return ccall((:ogg_page_serialno,libogg), Cint, (Ref{RawOggPage},), page)
end

"""
    ogg_page_pageno(page::RawOggPage)

Returns the page number of the given page
"""
function ogg_page_pageno(page::RawOggPage)
    return ccall((:ogg_page_pageno, libogg), Cint, (Ref{RawOggPage},), page)
end

"""
    ogg_page_eos(page::RawOggPage)

Indicates whether the given page is an end-of-stream
"""
function ogg_page_eos(page::RawOggPage)
    return ccall((:ogg_page_eos,libogg), Cint, (Ref{RawOggPage},), page) != 0
end

"""
    ogg_page_bos(page::RawOggPage)

Indicates whether the given page is an end-of-stream
"""
function ogg_page_bos(page::RawOggPage)
    return ccall((:ogg_page_bos,libogg), Cint, (Ref{RawOggPage},), page) != 0
end

"""
    ogg_page_granulepos(page::RawOggPage)

Returns the exact granular position of the packet data contained at the end of this page.

This is useful for tracking location when seeking or decoding.

For example, in audio codecs this position is the pcm sample number and in video this is the frame number.
"""
function ogg_page_granulepos(page::RawOggPage)
    return ccall((:ogg_page_granulepos, libogg), Int64, (Ref{RawOggPage},), page)
end

"""
Send a page into the `OggStreamstate` decoder

This copies the data that the `RawOggPage` points to (contained within the
`ogg_sync_state` struct) into the `ogg_stream_state` struct.

returns the updated streamstate
"""
function ogg_stream_pagein(streamstate::OggStreamState, page::RawOggPage)
    @debug "ogg_stream_pagein (header: $(page.header_len), body: $(page.body_len))"
    streamref = Ref(streamstate)
    status = ccall((:ogg_stream_pagein,libogg), Cint,
                   (Ref{OggStreamState}, Ref{RawOggPage}), streamref, page)
    if status != 0
        error("ogg_stream_pagein() failed with status $status")
    end

    streamref[]
end

"""
This function assembles a data packet for output to the codec decoding engine.
The data has already been submitted to the OggStreamState and broken into
segments. Each successive call returns the next complete packet built from those
segments.

In a typical decoding situation, this should be used after calling
ogg_stream_pagein() to submit a page of data to the bitstream.

If the function returns 0, more data is needed and another page should be
submitted. A positive return value indicates successful return of a packet.

The returned packet is filled in with pointers to memory managed by the stream
state and is only valid until the next call. The client must copy the packet
data if a longer lifetime is required.

Returns a pair of the packet and the new `streamstate`. The packet is a
`RawOggPacket` or `nothing` if the there isn't enough data buffered yet.
"""
function ogg_stream_packetout(streamstate::OggStreamState, isretry=false)
    streamref = Ref(streamstate)
    packetref = Ref(RawOggPacket())
    status = ccall((:ogg_stream_packetout,libogg), Cint,
                   (Ref{OggStreamState}, Ref{RawOggPacket}), streamref, packetref)
    if status == 1
        @debug "ogg_stream_packetout: status 1"
        packetref[], streamref[]
    elseif status == 0
        @debug "ogg_stream_packetout: status 0"
        nothing, streamref[]
    elseif status == -1 && !isretry
        @debug "ogg_stream_packetout unsynced, retrying..."
        ogg_stream_packetout(streamref[], true)
    else
        @warn "Got unexpected return value from ogg_stream_packetout: $status"
        nothing, streamref[]
    end
end
