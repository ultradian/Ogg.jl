__precompile__()
module Ogg
using FileIO
import Base: show, convert
export OggDecoder, OggEncoder, OggPage, PageSink
export serial, eos, bos
export eachpage

const depfile = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
if isfile(depfile)
    include(depfile)
else
    error("libogg not properly installed. Please run Pkg.build(\"Ogg\")")
end

include("types.jl")
include("decoder.jl")
include("encoder.jl")

end # module
