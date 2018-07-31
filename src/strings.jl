const INTERNED_STRINGS_POOL = [WeakKeyDict{String, Nothing}()]

@inline function intern!(wkd::WeakKeyDict{K}, key)::K where {K}
    index = Base.ht_keyindex2!(wkd.ht, key)
    if index > 0
        @inbounds found_key = wkd.ht.keys[index]
        return (found_key.value)::K
    else
        kk::K = convert(K, key)
        finalizer(wkd.finalizer, kk)
        @inbounds Base._setindex!(wkd.ht, nothing, WeakRef(kk), -index)
        return kk
    end
end
@inline intern(::Type{String}, x::Tuple{Ptr{UInt8}, Int}) = intern!(INTERNED_STRINGS_POOL[Threads.threadid()], x)
@inline intern(::Type{Tuple{Ptr{UInt8}, Int}}, x::Tuple{Ptr{UInt8}, Int}) = x

# taken from Base.hash for String
function Base.hash(x::Tuple{Ptr{UInt8},Int}, h::UInt)
    h += Base.memhash_seed
    ccall(Base.memhash, UInt, (Ptr{UInt8}, Csize_t, UInt32), x[1], x[2], h % UInt32) + h
end
Base.isequal(x::Tuple{Ptr{UInt8}, Int}, y::String) = hash(x) === hash(y)
Base.convert(::Type{String}, x::Tuple{Ptr{UInt8}, Int}) = unsafe_string(x[1], x[2])

const BUF = IOBuffer()
getptr(io::IO) = pointer(BUF.data, BUF.ptr)
getptr(io::IOBuffer) = pointer(io.data, io.ptr)
incr(io::IO, b) = Base.write(BUF, b)
incr(io::IOBuffer, b) = 1

@inline parse!(d::Delimited, io::IO, r::Result{T}; kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}} =
    parse!(d.next, io, r, d.delims; kwargs...)
@inline parse!(q::Quoted, io::IO, r::Result{T}, delims=nothing; kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}} =
    parse!(q.next, io, r, delims, q.openquotechar, q.closequotechar, q.escapechar; kwargs...)
@inline parse!(s::Strip, io::IO, r::Result{T}, delims=nothing, openquotechar=nothing, closequotechar=nothing, escapechar=nothing; kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}} =
    parse!(s.next, io, r, delims, openquotechar, closequotechar, escapechar; kwargs...)
@inline parse!(s::Sentinel, io::IO, r::Result{T}, delims=nothing, openquotechar=nothing, closequotechar=nothing, escapechar=nothing; kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}} =
    parse!(s.next, io, r, delims, openquotechar, closequotechar, escapechar, s.sentinels; kwargs...)
@inline parse!(::typeof(defaultparser), io::IO, r::Result{T}, delims=nothing, openquotechar=nothing, closequotechar=nothing, escapechar=nothing, node=nothing; kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}} =
    defaultparser(io, r, delims, openquotechar, closequotechar, escapechar, node; kwargs...)

@inline function defaultparser(io::IO, r::Result{T},
    delims=nothing, openquotechar=nothing, closequotechar=nothing, escapechar=nothing, node=nothing;
    kwargs...) where {T <: Union{Tuple{Ptr{UInt8}, Int}, AbstractString}}
    # @debug "xparse Sentinel, String: quotechar='$quotechar', delims='$delims'"
    ptr = getptr(io)
    len = 0
    b = 0x00
    code = OK
    quoted = false
    if !eof(io) && peekbyte(io) === openquotechar
        readbyte(io)
        ptr += 1
        quoted = true
    end
    if quoted
        len, b, code = handlequoted!(io, len, closequotechar, escapechar)
        if delims !== nothing
            if !eof(io)
                if match!(delims, io, r, false)
                    b = r.b
                else
                    code = INVALID
                    b = readbyte(io)
                    while !eof(io)
                        if match!(delims, io, r, false)
                            b = r.b
                            break
                        end
                        b = readbyte(io)
                    end
                end
            end
        end
    elseif delims !== nothing
        # read until we find a delimiter
        while !eof(io)
            if match!(delims, io, r, false)
                b = r.b
                break
            end
            b = readbyte(io)
            len += incr(io, b)
        end
    else
        # just read until eof
        while !eof(io)
            b = readbyte(io)
            len += incr(io, b) 
        end
    end
    # @debug "node=$node"
    r.b = b
    r.code = code
    setfield!(r, 1, match!(node, ptr, len) ? missing : intern(T, (ptr, len)))
    return r
end

function handlequoted!(io, len, closequotechar, escapechar)
    same = closequotechar === escapechar
    code = INVALID_QUOTED_FIELD
    b = 0x00
    while !eof(io)
        b = peekbyte(io)
        if same && b === escapechar
            readbyte(io)
            if eof(io) || peekbyte(io) !== closequotechar
                code = OK
                break
            end
            # otherwise, next byte is escaped, so read it
            len += incr(io, b)
            b = peekbyte(io)
        elseif b === escapechar
            readbyte(io)
            eof(io) && break
            # regular escaped byte
            len += incr(io, b)
            b = peekbyte(io)
        elseif b === closequotechar
            code = OK
            readbyte(io)
            break
        end
        len += incr(io, b)
        readbyte(io)
    end
    return len, b, code
end
