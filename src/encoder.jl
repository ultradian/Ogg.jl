type OggEncoder
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
        streamref = Ref{OggStreamState}(OggStreamState())
        status = ccall((:ogg_stream_init,libogg), Cint, (Ref{OggStreamState}, Cint), streamref, serial)
        if status != 0
            error("ogg_stream_init() failed: Unknown failure")
        end
        enc.streams[serial] = streamref[]

        # Also initialize enc.pages for this serial
        enc.pages[serial] = Vector{Vector{UInt8}}()
    end

    # Build ogg_packet structure
    packet = OggPacket( pointer(data), length(data), packet_idx == 0,
                        last_packet, granulepos, packet_idx )

    streamref = Ref{OggStreamState}(enc.streams[serial])
    packetref = Ref{OggPacket}(packet)
    status = ccall((:ogg_stream_packetin,libogg), Cint, (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
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
    streamref = Ref{OggStreamState}(enc.streams[serial])
    pageref = Ref{OggPage}(OggPage())
    status = ccall((:ogg_stream_pageout,libogg), Cint, (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
    enc.streams[serial] = streamref[]
    if status == 0
        return nothing
    else
        return pageref[]
    end
end

function ogg_stream_flush(enc::OggEncoder, serial::Clong)
    if !haskey(enc.streams, serial)
        return nothing
    end
    streamref = Ref{OggStreamState}(enc.streams[serial])
    pageref = Ref{OggPage}(OggPage())
    status = ccall((:ogg_stream_flush,libogg), Cint, (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
    enc.streams[serial] = streamref[]
    if status == 0
        return nothing
    else
        return pageref[]
    end
end


"""
Packets go in, pages come out
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
            # flushed into its own page
            if granulepos[serial][packet_idx] == 0
                page = ogg_stream_flush(enc, serial)
                while page != nothing
                    push!(pages, page)
                    page = ogg_stream_pageout(enc, serial)
                end
            end
        end

        # Take pages out and add them to our list of pages
        page = ogg_stream_pageout(enc, serial)
        while page != nothing
            push!(pages, page)
            page = ogg_stream_pageout(enc, serial)
        end

        # Flush the last pages out as well
        page = ogg_stream_flush(enc, serial)
        while page != nothing
            push!(pages, page)
            page = ogg_stream_pageout(enc, serial)
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

function save(file_path::Union{File{format"OGG"},AbstractString}, packets::Dict{Clong,Vector{Vector{UInt8}}}, granulepos::Dict{Clong,Vector{Int64}})
    open(file_path, "w") do fio
        save(fio, packets, granulepos)
    end
end

# Convenience save() function for single-stream Ogg files, assigns an arbitrary stream ID
function save(file_path::Union{File{format"OGG"},AbstractString,IO}, packets::Vector{Vector{UInt8}}, granulepos::Vector{Int64})
    return save(file_path, Dict(314159265 => packets), Dict(314159265 => granulepos))
end
