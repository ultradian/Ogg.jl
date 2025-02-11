mutable struct OggEncoder
    streams::Dict{Clong,OggStreamState}
    pages::Dict{Clong,Vector{Vector{UInt8}}}

    function OggEncoder()
        enc = new(Dict{Clong,OggStreamState}(), Dict{Clong,Vector{Vector{UInt8}}}())

        # This seems to be causing problems.  :(
        # finalizer(enc, x -> begin
        #     for serial in keys(x.streams)
        #         ogg_stream_destroy(x.streams[serial])
        #     end
        # end )

        return enc
    end
end

function show(io::IO, x::OggEncoder)
    num_streams = length(x.streams)
    if num_streams != 1
        write(io, "OggEncoder with $num_streams streams")
    else
        write(io, "OggEncoder with 1 stream")
    end
end

function ogg_stream_packetin(enc::OggEncoder, serial::Clong, data::Vector{UInt8}, packet_idx, last_packet::Bool, granulepos::Int64)
    if !haskey(enc.streams, serial)
        enc.streams[serial] = OggStreamState(serial)

        # Also initialize enc.pages for this serial
        enc.pages[serial] = Vector{UInt8}[]
    end

    # Build ogg_packet structure
    packet = RawOggPacket( pointer(data), length(data), packet_idx == 0,
                        last_packet, granulepos, packet_idx )

    streamref = Ref(enc.streams[serial])
    packetref = Ref(packet)
    GC.@preserve data begin
        status = ccall((:ogg_stream_packetin,libogg), Cint, (Ref{OggStreamState}, Ref{RawOggPacket}), streamref, packetref)
    end
    enc.streams[serial] = streamref[]
    if status == -1
        error("ogg_stream_packetin() failed: Unknown failure")
    end
    return nothing
end

function ogg_stream_pageout(enc::OggEncoder, serial::Clong)
    if !haskey(enc.streams, serial)
        return nothing
    end
    streamref = Ref(enc.streams[serial])
    pageref = Ref(RawOggPage())
    status = ccall((:ogg_stream_pageout,libogg), Cint, (Ref{OggStreamState}, Ref{RawOggPage}), streamref, pageref)
    enc.streams[serial] = streamref[]

    if status == 0
        return nothing
    else
        # pageref has pointers to data stored in streamref, so we need to make
        # sure that the stream is preserved until the data can be copied to
        # the OggPage
        @GC.preserve streamref begin
            return OggPage(pageref[])
        end
    end
end

function ogg_stream_flush(enc::OggEncoder, serial::Clong)
    if !haskey(enc.streams, serial)
        return nothing
    end
    streamref = Ref(enc.streams[serial])
    pageref = Ref(RawOggPage())
    status = ccall((:ogg_stream_flush,libogg), Cint, (Ref{OggStreamState}, Ref{RawOggPage}), streamref, pageref)
    enc.streams[serial] = streamref[]
    if status == 0
        return nothing
    else
        return OggPage(pageref[])
    end
end

"""
    encode_all_packets(enc, packets, granulepos)

Feed all packets (with their corresponding granule positions) into encoder `enc`.

Returns a list of pages, each a `Vector{UInt8}`
"""
function encode_all_packets(enc::OggEncoder, packets::Dict{Clong,Vector{Vector{UInt8}}}, granulepos::Dict{Clong,Vector{Int64}})
    pages = Vector{Vector{UInt8}}()

    # We're just going to chain streams together, not interleave them
    for serial in keys(packets)
        # Shove all packets into their own stream
        for packet_idx in 1:length(packets[serial])
            eos = packet_idx == length(packets[serial])
            ogg_stream_packetin(enc, serial, packets[serial][packet_idx], packet_idx - 1, eos, granulepos[serial][packet_idx])

            # A granulepos of zero signifies a header packet, which should be
            # flushed into its own page.  We know the header packets always
            # fit within a single page too, so we don't bother with the typical
            # while loop that would dump out excess data into its own page.
            if granulepos[serial][packet_idx] == 0
                page = ogg_stream_flush(enc, serial)
                # validatepage(Vector(page))
                push!(pages, Vector(page))
            else
                # generate a page if there's a "reasonable" amount of data in the buffer
                page = ogg_stream_pageout(enc, serial)
                while page !== nothing
                    # validatepage(Vector(page))
                    push!(pages, Vector(page))
                    page = ogg_stream_pageout(enc, serial)
                end
            end
        end

        # flush remaining data
        page = ogg_stream_flush(enc, serial)
        while page !== nothing
            # validatepage(Vector(page))
            push!(pages, Vector(page))
            page = ogg_stream_flush(enc, serial)
        end
    end

    # Flatten pages
    return pages
end

function save(fio::IO, packets::Dict{Clong,Vector{Vector{UInt8}}}, granulepos::Dict{Clong,Vector{Int64}})
    enc = OggEncoder()
    pages = encode_all_packets(enc, packets, granulepos)
    for page in pages
        write(fio, page)
    end
end

# function save(file_path::Union{File{format"OGG"},AbstractString}, packets::Dict{Clong,Vector{Vector{UInt8}}}, granulepos::Dict{Clong,Vector{Int64}})
#     open(file_path, "w") do fio
#         save(fio, packets, granulepos)
#     end
# end
#
# # Convenience save() function for single-stream Ogg files, assigns an arbitrary stream ID
# function save(file_path::Union{File{format"OGG"},AbstractString,IO}, packets::Vector{Vector{UInt8}}, granulepos::Vector{Int64})
#     return save(file_path, Dict(314159265 => packets), Dict(314159265 => granulepos))
# end
