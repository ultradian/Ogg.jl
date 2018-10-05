# this file has the low-level libogg types and wrappers for ccall functions. It
# provides some thin convenience wrappers but matches the same basic API as
# libogg

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
"""
function ogg_sync_clear(sync::Ref{OggSyncState})
    ccall((:ogg_sync_clear,libogg), Cint, (Ref{OggSyncState},), sync)
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

# This const here so that we don't use ... syntax in new()
const oss_zero_header = tuple(zeros(UInt8, 282)...)

"""
The ogg_stream_state struct tracks the current encode/decode state of the
current logical bitstream.
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
    granule_vals::Int64
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
    pageno::Cint
    # Number of the current packet
    packetno::Int64
    # Exact position of decoding/encoding process
    granulepos::Int64

    function OggStreamState(serialno)
        streamstate = Ref(new())
        status = ccall((:ogg_stream_init,libogg), Cint,
                       (Ref{OggStreamState}, Cint), streamstate, serialno)
        if status != 0
            error("ogg_stream_init() failed with status $status")
        end

        streamstate[]
    end
end

"""
This function clears and frees the internal memory used by the ogg_stream_state
struct, but does not free the structure itself. It is safe to call
ogg_stream_clear on the same structure more than once.
"""
function ogg_stream_clear(stream::Ref{OggStreamState})
    ccall((:ogg_stream_clear,libogg), Cint, (Ref{OggStreamState},), stream)
end

struct OggPacket
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
OggPacket() = OggPacket(C_NULL, 0, 0, 0, 0, 0)

function show(io::IO, x::OggPacket)
    write(io,"OggPacket ID: $(x.packetno), length $(x.bytes) bytes")
end

"""
    ogg_sync_buffer(dec::Ref{OggSyncState}, size)

Provide a buffer for writing new raw data into from the physical bitstream.

Buffer space which has already been returned is cleared, and the buffer is
extended as necessary by the `size` (in bytes) plus some additional bytes.
Within the current implementation, an extra 4096 bytes are allocated, but
applications should not rely on this additional buffer space.

Note that the argument is a reference to the `OggSyncState` object, which is
immutable to Julia but will be updated by libogg.

The buffer exposed by this function is empty internal storage from the
`OggSyncState` struct, beginning at the fill mark within the struct.

After copying data into this buffer you should call `ogg_sync_wrote` to tell the
`OggSyncState` struct how many bytes were actually written, and update the
fill mark.

Returns an `Array` wrapping the provided buffer.

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_buffer.html)
"""
function ogg_sync_buffer(syncstate::Ref{OggSyncState}, size)
    buffer = ccall((:ogg_sync_buffer,libogg), Ptr{UInt8},
                   (Ref{OggSyncState}, Clong),
                   syncstate, size)
    if buffer == C_NULL
        error("ogg_sync_buffer() failed: returned buffer NULL")
    end

    # note that the Array doesn't own the data, it will not be freed by Julia
    # when the array goes out of scope (which is what we want, because libogg
    # owns the data)
    return unsafe_wrap(Array, buffer, size)
end

"""
    ogg_sync_wrote(dec::Ref{OggSyncState}, size)

Tell the OggSyncState struct how many bytes we wrote into the buffer.

Note that the argument is a reference to the `OggSyncState` object, which is
immutable to Julia but will be updated by libogg.

The general proceedure is to request a pointer into an internal ogg_sync_state
buffer by calling ogg_sync_buffer(). The buffer is then filled up to the
requested size with new input, and ogg_sync_wrote() is called to advance the
fill pointer by however much data was actually written.
"""
function ogg_sync_wrote(syncstate::Ref{OggSyncState}, size)
    status = ccall((:ogg_sync_wrote, libogg), Cint,
                   (Ref{OggSyncState}, Clong),
                   syncstate, size)
    if status != 0
        error("ogg_sync_wrote() failed: error code $status")
    end

    nothing
end

"""
    ogg_sync_pageout(syncstate::Ref{OggSyncState})::Union{RawOggPage, Nothing}

Takes the data stored in the buffer of the OggSyncState and inserts them into an
ogg_page. Note that the payload data in the page is not copied, so the memory
the RawOggPage points to is still contained within the OggSyncState struct.

Note that the argument is a reference to the `OggSyncState` object, which is
immutable to Julia but will be updated by libogg.

Caution: This function should be called before reading into the buffer to ensure
that data does not remain in the OggSyncState struct. Failing to do so may
result in a memory leak. See the example code below for details.

Returns a new RawOggPage if it was available, or nothing if not (more data is
needed).

(docs adapted from https://xiph.org/ogg/doc/libogg/ogg_sync_pageout.html)
"""
function ogg_sync_pageout(syncstate::Ref{OggSyncState})
    page = Ref(RawOggPage())
    status = ccall((:ogg_sync_pageout,libogg), Cint,
                   (Ref{OggSyncState}, Ref{RawOggPage}),
                   syncstate, page)
    if status == 1
        return page[]
    else
        return nothing
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

# """
# Send a page in, return the serial number of the stream that we just decoded.
#
# This copies the data that the OggPage points to (contained within the
# `ogg_sync_state` struct) into the `ogg_stream_state` struct.
# """
# function ogg_stream_pagein(streamref::Ref{OggStreamState}, page::OggPage)
#     pageref = Ref(page)
#     status = ccall((:ogg_stream_pagein,libogg), Cint,
#                    (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
#     if status != 0
#         error("ogg_stream_pagein() failed with status $status")
#     end
#     nothing
# end
#
# # note that this doesn't actually copy the data into the packet, it just makes
# # the packet point to the data within the stream
# function ogg_stream_packetout(streamref::Ref{OggStreamState}, retry=false)
#     packetref = Ref{OggPacket}(OggPacket())
#     status = ccall((:ogg_stream_packetout,libogg), Cint,
#                    (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
#     if status == 1
#         return packetref[]
#     else
#         # Is our status -1?  That means we're desynchronized and should try again, at least once
#         if status == -1 && !retry
#             return ogg_stream_packetout(dec, serial; retry = true)
#         end
#         return nothing
#     end
# end
