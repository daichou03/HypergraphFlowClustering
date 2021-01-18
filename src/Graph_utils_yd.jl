using SparseArrays
using MAT
using MatrixNetworks
using LinearAlgebra
using StatsBase # TODO: To install
using Random
include("maxflow.jl")
include("Helper_io.jl")
include("Core_algorithm_yd.jl")

#------------
# Graph Utils
#------------

function GetDegree(B::SparseMatrixCSC, V::Int64)
    sum(B[V,:])
end

function GetAdjacency(B::SparseMatrixCSC, V::Int64, Self::Bool=true)
    N = size(B,1)
    L = map(z->z[1], filter(a->a[2]>0, collect(zip(1:N,B[V,:]))))
    if Self
        L = prepend!(L, V)
    end
    return L
end

# Use Set to rewrite this.
# YD 20210114: Depends on Size, get faster than V1 with larger size.
# Compared with V1:
# 120% time on |S| = 20 - 200
# 91% time on |S| = 2000
function GetSampleUntilSizeV2(B::SparseMatrixCSC, V::Int64, Size::Int64)
    r = [V]
    adj_set = Set(GetAdjacency(B, V, false))
    size = 1
    while size < Size && length(adj_set) > 0
        next = rand(adj_set)
        append!(r, next)
        adj_set = setdiff(union(adj_set, Set(GetAdjacency(B, next, true))), Set([next]))
        size += 1
    end
    return r
end

# Connected components

# Not very efficient on large?
# Returns the Set of the connected component that #1 vertex is in.
function ExtractConnectedComponent(B::SparseMatrixCSC)
    explored = Set(GetAdjacency(B,1,true))
    adj_set = setdiff(explored, Set([1]))
    while length(adj_set) > 0
        adj_set = setdiff(SetGetComponentAdjacency(B, collect(adj_set), false), explored)
        explored = union(explored, adj_set)
    end
    return explored
end

# Returns the number of connected components.
# If ReturnLargestCCIndex, returns the largest connected component's index INSTEAD (I know this is bad code, not necessary to make it better for now).
# Also if want to know the largest CC's index, definitely can stop early.
function DetectConnectedComponents(B::SparseMatrixCSC, ReturnLargestCCIndex::Bool=false, ShowLengthOfComponents::Bool=false)
    remaining = copy(B)
    components = 0
    largestCCIndex = 1
    largestCC = 0
    while size(remaining, 1) > 0
        nextCC = ExtractConnectedComponent(remaining)
        remaining_components = collect(setdiff(Set(1:size(remaining, 1)), nextCC))
        remaining = remaining[remaining_components, remaining_components]
        components += 1
        if components == 1 || length(largestCC) < length(nextCC)
            largestCC = nextCC
            largestCCIndex = components
        end
        if ShowLengthOfComponents
            println(string("Length of connected component #", components, ": ", length(nextCC)))
        end
    end
    if ReturnLargestCCIndex
        return largestCCIndex
    else
        return components
    end
end

function RetrieveLargestConnectedComponent(B::SparseMatrixCSC)
    largestCCIndex = DetectConnectedComponents(B, true, false)
    remaining = copy(B)
    for i = 1:largestCCIndex-1
        nextCC = ExtractConnectedComponent(remaining)
        remaining_components = collect(setdiff(Set(1:size(remaining, 1)), nextCC))
        remaining = remaining[remaining_components, remaining_components]
    end
    nextCC = collect(ExtractConnectedComponent(remaining))
    return B[nextCC,nextCC]
end

function DetectConnectedComponents(B::SparseMatrixCSC, ShowLengthOfComponents::Bool=false)
    remaining = copy(B)
    components = 0
    while size(remaining, 1) > 0
        explored = Set(GetAdjacency(remaining,1,true))
        adj_set = setdiff(explored, Set([1]))
        while length(adj_set) > 0
            adj_set = setdiff(SetGetComponentAdjacency(remaining, collect(adj_set), false), explored)
            explored = union(explored, adj_set)
        end
        remaining_components = collect(setdiff(Set(1:size(remaining, 1)), explored))
        remaining = remaining[remaining_components, remaining_components]
        components += 1
        if ShowLengthOfComponents
            println(string("Length of connected component #", components, ": ", length(explored)))
        end
    end
    return components
end

# Note there are |S| convertions from array to set, and 1 conversion from set to array.
function GetComponentAdjacency(B::SparseMatrixCSC, S::Vector{Int64}, Self::Bool=true)
    return collect(SetGetComponentAdjacency(B,S,Self))
end

function SetGetComponentAdjacency(B::SparseMatrixCSC, S::Vector{Int64}, Self::Bool=true)
    N = size(B,1)
    L = reduce(union, map(x->Set(GetAdjacency(B,x,true)), S))
    if !Self
        L = setdiff(L, Set(S))
    end
    return L
end

function GetVolume(B::SparseMatrixCSC, S::Vector{Int64})
    sum(map(v->GetDegree(B,v), S))
end

function GetAllDegrees(B::SparseMatrixCSC)
    N = size(B,1)
    collect(zip(1:N, map(v->GetDegree(B,v), 1:N)))
end

function GetInducedVolume(B::SparseMatrixCSC, S::Vector{Int64})
    sum(B[S,S])
end

function GetGenericSeedReport(B::SparseMatrixCSC, V::Int64, R::Vector{Int64})
    inducedMD = GlobalMaximumDensity(B[R,R])
    localMD = LocalMaximumDensity(B, R)
    rSeed(V, R, GetDegree(B, V), GetVolume(B, R), GetInducedVolume(B, R), inducedMD.alpha_star, length(inducedMD.source_nodes)-1, localMD.alpha_star, length(localMD.source_nodes)-1)
end
