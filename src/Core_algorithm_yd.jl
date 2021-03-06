using SparseArrays
using MAT
using MatrixNetworks
using LinearAlgebra
using Base
include("maxflow.jl") # TODO: Credit
include("Helper_io.jl")
include("Graph_utils_yd.jl")
include("Utils.jl")

# For undirected and unweighted graph.

mutable struct densestSubgraph
    alpha_star::Float64 # The minimum alpha value that can saturate all source edges
    source_nodes::Vector{Int64} # give the indices of the nodes attached to the source. Note this includes source node with index = 1, and all nodes' indices are 1 greater.
end

function GlobalMaximumDensity(B::SparseMatrixCSC)
    N = size(B,1)
    # Weight for source edges
    sWeights = map(x -> GetDegree(B,x), 1:N)
    alpha_bottom = sum(sWeights) / N # Reachable
    alpha_top = maximum(sWeights) # Reachable only if alpha_bottom = alpha_top, i.e. the entire graph is a clique
    flow_alpha_minus = 0
    alpha_star = 0

    if FlowWithAlpha(B, alpha_bottom, sWeights).flowvalue >= sum(sWeights) - 1e-6
        alpha_star = alpha_bottom
        flow_alpha_minus = FlowWithAlpha(B, alpha_star - 1 / (N * (N+1)), sWeights)
    else
        while alpha_top - alpha_bottom >= 1 / (N * (N+1))
            alpha = (alpha_bottom + alpha_top) / 2
            F = FlowWithAlpha(B, alpha, sWeights)
            if F.flowvalue >= sum(sWeights) - 1e-6 # YD 20201223: tolerance doesn't matter much, just don't trust alpha_top
                alpha_top = alpha
            else
                alpha_bottom = alpha
            end
            # println(alpha)
        end
        flow_alpha_minus = FlowWithAlpha(B, alpha_bottom, sWeights)
        subgraph_length = length(flow_alpha_minus.source_nodes) - 1
        alpha_star = Float64(floor((alpha_bottom * subgraph_length) + 1) / subgraph_length)
    end
    return densestSubgraph(alpha_star, PopSourceForFlowNetworkResult(flow_alpha_minus.source_nodes))
end

function FlowWithAlpha(B::SparseMatrixCSC, alpha::Float64, sWeights::Vector{Int64})
    N = size(B,1)
    FlowNet = [spzeros(1,1) sparse(sWeights') spzeros(1,1);
               spzeros(N,1) B                 sparse(repeat([alpha], N));
               spzeros(1,N+2)]
    F = maxflowPR(FlowNet, 1, N+2)
    return F
end

# inducedDS = GlobalMaximumDensity(B[R,R])
function LocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, inducedDS::densestSubgraph, ShowTrace::Bool=false)
    N = size(B,1)
    # Weight for source edges
    # sWeightsR = map(x -> sum(B[x,:]), R)
    sWeightsR = map(x -> (x in R) ? GetDegree(B,x) : 0, 1:N)
    density_R = inducedDS.alpha_star # Density of the densest subgraph of R
    if density_R < 1 # 20210122: This should only happen when no vertices in R connects to each other. In which case the density should be 0, and pick no vertices other than the source.
        return inducedDS
    end
    alpha_bottom = density_R # Reachable (degenerate case)
    alpha_top = length(R) # Not reachable
    flow_alpha_minus = 0
    alpha_star = 0

    FlowNetTemp = [spzeros(1,1) sparse(sWeightsR') spzeros(1,1);
                   spzeros(N,1) B                  sparse(repeat([1], N));
                   spzeros(1,N+2)]

    if FlowWithAlphaLocalDensity(FlowNetTemp, alpha_bottom).flowvalue >= sum(sWeightsR) - 1e-6
        alpha_star = alpha_bottom
        flow_alpha_minus = FlowWithAlphaLocalDensity(FlowNetTemp, alpha_star - 1 / (N * (N+1)))
    else
        while alpha_top - alpha_bottom >= 1 / (N * (N+1))
            alpha = (alpha_bottom + alpha_top) / 2
            F = FlowWithAlphaLocalDensity(FlowNetTemp, alpha)
            if F.flowvalue >= sum(sWeightsR) - 1e-6
                alpha_top = alpha
            else
                alpha_bottom = alpha
            end
            if ShowTrace
                println(string("Current alpha: ", alpha))
            end
        end
        flow_alpha_minus = FlowWithAlphaLocalDensity(FlowNetTemp, alpha_bottom)
        subgraph_length = length(flow_alpha_minus.source_nodes) - 1
        alpha_star = Float64((floor(alpha_bottom * subgraph_length) + 1) / subgraph_length)
    end
    return densestSubgraph(alpha_star, PopSourceForFlowNetworkResult(flow_alpha_minus.source_nodes))
end

function LocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, ShowTrace::Bool=false)
    inducedDS = GlobalMaximumDensity(B[R,R])
    return LocalMaximumDensity(B, R, inducedDS, ShowTrace)
end

function FlowWithAlphaLocalDensity(FlowNet::SparseMatrixCSC, alpha::Float64)
    N = size(FlowNet,1) - 2
    for i = 2:N+1
        FlowNet[i, N+2] = alpha
    end
    F = maxflowPR(FlowNet, 1, N+2)
    return F
end

# globalDegree and orderByDegreeIndices are information global to B. Pre-calculate them as below:
# globalDegree = map(x -> GetDegree(B,x), 1:size(B,1))
# orderByDegreeIndices = GetOrderByDegreeGraphIndices(B)

# inducedDS = GlobalMaximumDensity(B[R,R])
function ImprovedLocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, globalDegree::Vector{Int64}, orderByDegreeIndices::Array{Tuple{Int64,Int64},1}, inducedDS::densestSubgraph)
    N = size(B,1)
    # Weight for source edges
    sWeightsR = map(x -> (x in R) ? globalDegree[x] : 0, 1:N)
    volume_R = sum(sWeightsR)
    overdensed = GetOverdensedNodes(N, orderByDegreeIndices, volume_R)
    rToOMatrix = B[overdensed, setdiff(1:N,overdensed)]
    rToOWeights = map(x -> GetDegree(rToOMatrix, x), 1:(N-length(overdensed)))
    BProp = B[setdiff(1:N,overdensed), setdiff(1:N,overdensed)]
    sWeightsRProp = sWeightsR[setdiff(1:N,overdensed)]

    density_R = inducedDS.alpha_star
    alpha_bottom = density_R # Reachable
    alpha_top = length(R) # Not reachable
    flow_alpha_minus = 0
    alpha_star = 0

    # YD: Just merge the super node with sink. Also ignore any directed edges from it to regular nodes.
    if FlowWithAlphaImprovedLocalDensity(BProp, R, alpha_bottom, sWeightsRProp, rToOWeights).flowvalue >= sum(sWeightsR) - 1e-6
        alpha_star = alpha_bottom
        flow_alpha_minus = FlowWithAlphaImprovedLocalDensity(BProp, R, alpha_star - 1 / (N * (N+1)), sWeightsRProp, rToOWeights)
    else
        while alpha_top - alpha_bottom >= 1 / (N * (N+1))
            alpha = (alpha_bottom + alpha_top) / 2
            F = FlowWithAlphaImprovedLocalDensity(BProp, R, alpha, sWeightsRProp, rToOWeights)
            if F.flowvalue >= sum(sWeightsR) - 1e-6
                alpha_top = alpha
            else
                alpha_bottom = alpha
            end
            # println(alpha)
        end
        flow_alpha_minus = FlowWithAlphaImprovedLocalDensity(BProp, R, alpha_bottom, sWeightsRProp, rToOWeights)
        subgraph_length = length(flow_alpha_minus.source_nodes) - 1
        alpha_star = Float64((floor(alpha_bottom * subgraph_length) + 1) / subgraph_length)
    end

    return densestSubgraph(alpha_star, PopSourceForFlowNetworkResult(flow_alpha_minus.source_nodes))
end

function ImprovedLocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, globalDegree::Vector{Int64}, orderByDegreeIndices::Array{Tuple{Int64,Int64},1})
    inducedDS = GlobalMaximumDensity(B[R,R])
    return ImprovedLocalMaximumDensity(B, R, globalDegree, orderByDegreeIndices, inducedDS)
end

function GetOverdensedNodes(N::Int64, orderByDegreeIndices::Array{Tuple{Int64,Int64},1}, volume_R::Union{Int64,Float64})
    overdensed_ind_low = 1
    overdensed_ind_high = N + 1
    overdensed_ind_curr = overdensed_ind_low
    while overdensed_ind_low < overdensed_ind_high
        overdensed_ind_curr = (overdensed_ind_low + overdensed_ind_high) ÷ 2
        if orderByDegreeIndices[overdensed_ind_curr][2] >= volume_R
            overdensed_ind_high = overdensed_ind_curr
        else
            overdensed_ind_low = overdensed_ind_curr + 1
        end
    end
    overdensed = map(x->x[1], orderByDegreeIndices[overdensed_ind_curr:N])
    # println(string("Overdensed nodes: ", length(overdensed), " / ", N))
end

function FlowWithAlphaImprovedLocalDensity(BProp::SparseMatrixCSC, R::Vector{Int64}, alpha::Float64, sWeightsR::Vector{Int64}, rToOWeights::Vector{Int64})
    NProp = size(BProp,1)

#    Supernode version
#    FlowNet = [spzeros(1,1)     sparse(sWeightsR')   spzeros(1,2);
#               spzeros(NProp,1) BProp               sparse(rToOWeights') sparse(repeat([alpha], NProp));
#               spzeros(1,1)     sparse(oToRWeights) spzeros(1,1)         infValue;
#               spzeros(1,NProp+3)]
#    F = maxflowPR(FlowNet, 1, NProp+3)

    # Supernode = sink version
    FlowNet = [spzeros(1,1)     sparse(sWeightsR') spzeros(1,1);
               spzeros(NProp,1) BProp              sparse(repeat([alpha], NProp) + rToOWeights);
               spzeros(1,NProp+2)]
    F = maxflowPR(FlowNet, 1, NProp+2)
    return F
end

# inducedDS = GlobalMaximumDensity(B[R,R])
function StronglyLocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, inducedDS::densestSubgraph, ShowTrace::Bool=false)
    Expanded = Int64[]
    RSorted = sort(R)
    Frontier = RSorted
    alpha = 0
    S = Int64[]
    SUnion = Int64[]
    L = Int64[]
    while !isempty(Frontier)
        Expanded = union(Expanded, Frontier)
        L = sort(union(L, GetComponentAdjacency(B, Frontier, true))) # GetComponentAdjacency is expensive, doing it incrementally.
        result_S = LocalMaximumDensity(B[L,L], orderedSubsetIndices(L, RSorted), inducedDS)
        alpha = result_S.alpha_star
        S = L[result_S.source_nodes]
        if ShowTrace
            println(densestSubgraph(result_S.alpha_star, S))
        end
        SUnion = union(SUnion, S)
        Frontier = setdiff(S, Expanded)
    end
    return densestSubgraph(alpha, S)
end

function StronglyLocalMaximumDensity(B::SparseMatrixCSC, R::Vector{Int64}, ShowTrace::Bool=false)
    inducedDS = GlobalMaximumDensity(B[R,R])
    return StronglyLocalMaximumDensity(B, R, inducedDS, ShowTrace)
end
