"""
    function compress(model::Flux.Chain, init_ub::Vector{Float64}, init_lb::Vector{Float64}; params=nothing, bounds_U=nothing, bounds_L=nothing, tighten_bounds="fast")

Creates a new neural network model by identifying stabily active and inactive neurons and removing them.

Can be called with precomputed bounds.
Returns the compressed neural network as a `Flux.Chain` and the indices of the removed neurons in this case.

Can also be called without the bounds to invoke bound tightening ("standard" or "fast" mode). In this case solver parameters have to be provided.
Returns the resulting JuMP model, the compressed neural network, the removed neurons and the computed bounds.

# Arguments
- `NN_model`: neural network as a `Flux.Chain`
- `init_ub`: upper bounds for the input layer
- `init_lb`: lower bounds for the input layer

# Optional arguments
- `params`: parameters for the JuMP model solver
- `tighten_bounds`: "fast" or "standard"
- `bounds_U`: upper bounds for the hidden and output layers
- `bounds_L`: lower bounds for the hidden and output layers

# Examples
```julia
julia> jump_model, compressed_model, removed_neurons, bounds_U, bounds_L = compress(model, init_U, init_L; params=solver_params, tighten_bounds="standard");
```
"""
function compress(model::Flux.Chain, init_ub::Vector{Float64}, init_lb::Vector{Float64}; params=nothing, bounds_U=nothing, bounds_L=nothing, tighten_bounds="fast")

    println("Starting neural network compression...")

    with_tightening = (bounds_U === nothing || bounds_L === nothing)
    with_tightening && @assert params !== nothing "Solver parameters must be provided."
    @assert tighten_bounds in ("fast", "standard")

    K = length(model)

    @assert all([model[i].σ == relu for i in 1:K-1]) "Neural network must use the relu activation function."
    @assert model[K].σ == identity "Neural network must use the identity function for the output layer."

    W = deepcopy([Flux.params(model)[2*k-1] for k in 1:K]) # W[i] = weight matrix for i:th layer
    b = deepcopy([Flux.params(model)[2*k] for k in 1:K])

    removed_neurons = Vector{Vector}(undef, K)
    [removed_neurons[layer] = Vector{Int}() for layer in 1:K]

    input_length = Int((length(W[1]) / length(b[1])))
    neuron_count = [length(b[k]) for k in eachindex(b)]
    neurons(layer) = layer == 0 ? [i for i in 1:input_length] : [i for i in setdiff(1:neuron_count[layer], removed_neurons[layer])]

    if with_tightening
        bounds_U = Vector{Vector}(undef, K)
        bounds_L = Vector{Vector}(undef, K)
    end

    # build JuMP model
    if tighten_bounds == "standard"
        jump_model = Model()
        set_solver_params!(jump_model, params)
        
        @variable(jump_model, x[layer = 0:K, neurons(layer)])
        @variable(jump_model, s[layer = 1:K-1, neurons(layer)])
        @variable(jump_model, z[layer = 1:K-1, neurons(layer)])
        
        @constraint(jump_model, [j = 1:input_length], x[0, j] <= init_ub[j])
        @constraint(jump_model, [j = 1:input_length], x[0, j] >= init_lb[j])
    end

    layers_removed = 0 # how many strictly preceding layers have been removed at current loop iteration 

    for layer in 1:K # hidden layers and bounds for output layer

        println("\nLAYER $layer")

        if with_tightening

            # compute loose bounds
            if layer - layers_removed == 1
                bounds_U[layer] = [sum(max(W[layer][neuron, previous] * init_ub[previous], W[layer][neuron, previous] * init_lb[previous]) for previous in neurons(layer-1-layers_removed)) + b[layer][neuron] for neuron in neurons(layer)]
                bounds_L[layer] = [sum(min(W[layer][neuron, previous] * init_ub[previous], W[layer][neuron, previous] * init_lb[previous]) for previous in neurons(layer-1-layers_removed)) + b[layer][neuron] for neuron in neurons(layer)]
            else
                bounds_U[layer] = [sum(max(W[layer][neuron, previous] * max(0, bounds_U[layer-1-layers_removed][previous]), W[layer][neuron, previous] * max(0, bounds_L[layer-1-layers_removed][previous])) for previous in neurons(layer-1-layers_removed)) + b[layer][neuron] for neuron in neurons(layer)]
                bounds_L[layer] = [sum(min(W[layer][neuron, previous] * max(0, bounds_U[layer-1-layers_removed][previous]), W[layer][neuron, previous] * max(0, bounds_L[layer-1-layers_removed][previous])) for previous in neurons(layer-1-layers_removed)) + b[layer][neuron] for neuron in neurons(layer)]
            end

            if tighten_bounds == "standard"
                bounds = if nprocs() > 1
                    pmap(neuron -> calculate_bounds(copy_model(jump_model, solver_params), layer, neuron, W, b, neurons; layers_removed), neurons(layer))
                else
                    map(neuron -> calculate_bounds(jump_model, layer, neuron, W, b, neurons; layers_removed), neurons(layer))
                end
                # only change if bound is improved
                bounds_U[layer] = min.(bounds_U[layer], [bound[1] for bound in bounds])
                bounds_L[layer] = max.(bounds_L[layer], [bound[2] for bound in bounds])
            end
        end

        if layer == K
            break
        end

        layers_removed = prune!(W, b, removed_neurons, layers_removed, neuron_count, layer, bounds_U, bounds_L)

        if tighten_bounds == "standard"
            for neuron in neurons(layer)
                @constraint(jump_model, x[layer, neuron] >= 0)
                @constraint(jump_model, s[layer, neuron] >= 0)
                set_binary(z[layer, neuron])

                @constraint(jump_model, x[layer, neuron] <= max(0, bounds_U[layer][neuron]) * (1 - z[layer, neuron]))
                @constraint(jump_model, s[layer, neuron] <= max(0, -bounds_L[layer][neuron]) * z[layer, neuron])

                @constraint(jump_model, x[layer, neuron] - s[layer, neuron] == b[layer][neuron] + sum(W[layer][neuron, i] * x[layer-1-layers_removed, i] for i in neurons(layer-1-layers_removed)))
            end
        end

        if length(neurons(layer)) > 0
            layers_removed = 0
        end 

    end

    # output layer
    tighten_bounds == "standard" && @constraint(jump_model, [neuron in neurons(K)], x[K, neuron] == b[K][neuron] + sum(W[K][neuron, i] * x[K-1-layers_removed, i] for i in neurons(K-1-layers_removed)))

    println("Compression complete.")

    new_model = build_model!(W, b, K, neurons)

    if with_tightening

        U_compressed = [bounds_U[layer][neurons(layer)] for layer in 1:K]
        filter!(neurons -> length(neurons) != 0, U_compressed)

        L_compressed = [bounds_L[layer][neurons(layer)] for layer in 1:K]
        filter!(neurons -> length(neurons) != 0, L_compressed)

        jump_model = NN_to_MIP(new_model, init_ub, init_lb, params; bounds_U=U_compressed, bounds_L=L_compressed)[1]

        return jump_model, new_model, removed_neurons, U_compressed, L_compressed
    else
        return new_model, removed_neurons
    end
end