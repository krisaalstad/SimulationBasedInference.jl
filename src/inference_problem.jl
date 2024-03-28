#### Inverse/inference problems ####

"""
    SimulatorInferenceProblem{modelPriorType<:AbstractPrior,uType,solverType} <: SciMLBase.AbstractSciMLProblem

Represents a generic simulation-based Bayesian inference problem for finding the posterior distribution over model parameters given some observed data.
"""
struct SimulatorInferenceProblem{modelPriorType<:AbstractPrior,uType,solverType} <: SciMLBase.AbstractSciMLProblem
    u0::uType
    forward_prob::SimulatorForwardProblem
    forward_solver::solverType
    prior::JointPrior{modelPriorType}
    likelihoods::NamedTuple
    metadata::Dict
end

"""
    SimulatorInferenceProblem(
        prob::SimulatorForwardProblem,
        forward_solver,
        prior::AbstractPrior,
        likelihoods::SimulatorLikelihood...;
        metadata::Dict=Dict(),
    )

Constructs a `SimulatorInferenceProblem` from the given forward problem, prior, and likelihoods.
Additional user-specified metadata may be included in the `metadata` dictionary.
"""
function SimulatorInferenceProblem(
    forward_prob::SimulatorForwardProblem,
    forward_solver,
    prior::AbstractPrior,
    likelihoods::SimulatorLikelihood...;
    metadata::Dict=Dict(),
)
    joint_prior = JointPrior(prior, likelihoods...)
    u0 = zero(rand(joint_prior))
    return SimulatorInferenceProblem(u0, forward_prob, forward_solver, joint_prior, with_names(likelihoods), metadata)
end
SimulatorInferenceProblem(forward_prob::SimulatorForwardProblem, prior::AbstractPrior, likelihoods::SimulatorLikelihood...; kwargs...) =
    SimulatorInferenceProblem(forward_prob, nothing, prior, likelihoods...; kwargs...)

"""
    prior(prob::SimulatorInferenceProblem)

Retrieves the prior from the given `SimulatorInferenceProblem`.
"""
prior(prob::SimulatorInferenceProblem) = prob.prior

SciMLBase.isinplace(prob::SimulatorInferenceProblem) = false

function SciMLBase.remaker_of(prob::SimulatorInferenceProblem)
    function remake(;
        u0=prob.u0,
        forward_prob=prob.forward_prob,
        forward_solver=prob.forward_solver,
        prior=prob.prior,
        likelihoods=prob.likelihoods,
        metadata=prob.metadata,
    )
        SimulatorInferenceProblem(u0, forward_prob, forward_solver, prior, likelihoods, metadata)
    end
end

Base.names(prob::SimulatorInferenceProblem) = keys(prob.likelihoods)

Base.propertynames(prob::SimulatorInferenceProblem) = (fieldnames(typeof(prob))..., propertynames(getfield(prob, :forward_prob))...)
function Base.getproperty(prob::SimulatorInferenceProblem, sym::Symbol)
    if sym ∈ fieldnames(typeof(prob))
        return getfield(prob, sym)
    end
    return getproperty(getfield(prob, :forward_prob), sym)
end

function forward_eval!(inference_prob::SimulatorInferenceProblem, θ::ComponentVector; solve_kwargs...)
    ζ = forward_map(inference_prob.prior, θ)
    solver = init(inference_prob.forward_prob, inference_prob.forward_solver; p=ζ.model, solve_kwargs...)
    solve!(solver)
    loglik = sum(map(l -> loglikelihood(l, getproperty(ζ, nameof(l))), inference_prob.likelihoods), init=0.0)
    return loglik
end

"""
    logjoint(inference_prob::SimulatorInferenceProblem, u::AbstractVector; transform=false, forward_solve=true, solve_kwargs...)

Evaluate the the log-joint density components `log(p(D|x))` and `log(p(u))` where `D` is the data and `u` are the parameters.
If `transform=true`, `x` is transformed by the `param_map` defined on the given inference problem before evaluating
the density.
"""
function logjoint(
    inference_prob::SimulatorInferenceProblem,
    u::AbstractVector;
    transform=false,
    forward_solve=true,
    solve_kwargs...
)
    uvec = zero(inference_prob.u0) .+ u
    logprior = zero(eltype(u))
    # transform from unconstrained space if necessary
    if transform
        f = inverse(bijector(inference_prob))
        ϕvec = f(uvec)
        θ = zero(uvec) + ϕvec
        # add density change due to transform
        logprior += logabsdetjac(f, uvec)
    else
        θ = uvec
    end
    logprior += logprob(inference_prob.prior, θ)
    # solve forward problem;
    loglik = if forward_solve
        forward_eval!(inference_prob, θ; solve_kwargs...)
    else
        # check that parameters match
        @assert all(θ.model .≈ inference_prob.forward_prob.p) "forward problem model parameters do not match the given parameters"
        # evaluate log likelihood
        sum(map(l -> loglikelihood(l, getproperty(θ, nameof(l))), inference_prob.likelihoods), init=0.0)
    end
    return (; loglik, logprior)
end

function logjoint(
    inference_prob::SimulatorInferenceProblem,
    forward_sol::SimulatorForwardSolution,
    u::AbstractVector;
    transform=false,
    solve_kwargs...
)
    observables = forward_sol.prob.observables
    new_likelihoods = map(l -> remake(l, obs=getproperty(observables, nameof(l))), inference_prob.likelihoods)
    new_inference_prob = remake(inference_prob; forward_prob=forward_sol.prob, likelihoods=new_likelihoods)
    return logjoint(new_inference_prob, u; transform, forward_solve=false, solve_kwargs...)
end

logprob(inference_prob::SimulatorInferenceProblem, u) = sum(logjoint(inference_prob, u, transform=false))

"""
    logdensity(inference_prob::SimulatorInferenceProblem, x; kwargs...)

Applies the inverse transformation defined by `bijector` and calculates the
`logjoint` density. Note that this requires evaluating the likelihood/forward-map, which
may involve running the simulator.
"""
function LogDensityProblems.logdensity(inference_prob::SimulatorInferenceProblem, x; kwargs...)
    lp = sum(logjoint(inference_prob, x; transform=true, kwargs...))
    return lp
end

# log density interface

LogDensityProblems.capabilities(::Type{<:SimulatorInferenceProblem}) = LogDensityProblems.LogDensityOrder{0}()

LogDensityProblems.dimension(inference_prob::SimulatorInferenceProblem) = length(inference_prob.u0)

Bijectors.bijector(prob::SimulatorInferenceProblem) = bijector(prob.prior)

function Base.show(io::IO, ::MIME"text/plain", prob::SimulatorInferenceProblem)
    println(io, "SimulatorInferenceProblem with $(length(prob.u0)) parameters and $(length(prob.likelihoods)) likelihoods")
    println(io, "    Parameters: $(labels(prob.u0))")
    println(io, "    Likelihoods: $(keys(prob.likelihoods))")
    println(io, "    Observables: $(keys(prob.observables))")
    println(io, "    Forward problem type: $(typeof(prob.forward_prob.prob))")
    println(io, "    Forward solver: $(isnothing(prob.forward_solver) ? "none" : typeof(prob.forward_solver))")
    println(io, "    Prior type: $(typeof(prob.prior))")
    println(io, "    Metadata: $(prob.metadata)")
end

"""
    SimulatorInferenceSolution{algType,probType,storageType}

Generic container for solutions to `SimulatorInferenceProblem`s. The type of `result` is method dependent
and should generally correspond to the final state or product of the inference algorithm (e.g. posterior sampels).
The field `output` should be an instance of `SimulationData`
"""
mutable struct SimulatorInferenceSolution{algType,probType,storageType}
    prob::probType
    alg::algType
    storage::storageType
    result::Any
end

getinputs(sol::SimulatorInferenceSolution, args...) = getinputs(sol.storage, args...)

getoutputs(sol::SimulatorInferenceSolution, args...) = getoutputs(sol.storage, args...)
