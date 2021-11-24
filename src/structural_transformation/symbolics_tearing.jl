function tearing_sub(expr, dict, s)
    expr = ModelingToolkit.fixpoint_sub(expr, dict)
    s ? simplify(expr) : expr
end

function tearing_reassemble(sys; simplify=false)
    s = structure(sys)
    @unpack fullvars, partitions, var_eq_matching, graph, scc = s
    eqs = equations(sys)

    ### extract partition information
    rhss = []
    solvars = []
    ns, nd = nsrcs(graph), ndsts(graph)
    active_eqs  = trues(ns)
    active_vars = trues(nd)
    rvar2reqs = Vector{Vector{Int}}(undef, nd)
    for (ith_scc, partition) in enumerate(partitions)
        @unpack e_solved, v_solved, e_residual, v_residual = partition
        for ii in eachindex(e_solved)
            ieq = e_solved[ii]; ns -= 1
            iv = v_solved[ii]; nd -= 1
            rvar2reqs[iv] = e_solved

            active_eqs[ieq] = false
            active_vars[iv] = false

            eq = eqs[ieq]
            var = fullvars[iv]
            rhs = value(solve_for(eq, var; simplify=simplify, check=false))
            # if we don't simplify the rhs and the `eq` is not solved properly
            (!simplify && occursin(rhs, var)) && (rhs = SymbolicUtils.polynormalize(rhs))
            # Since we know `eq` is linear wrt `var`, so the round off must be a
            # linear term. We can correct the round off error by a linear
            # correction.
            rhs -= expand_derivatives(Differential(var)(rhs))*var
            @assert !(var in vars(rhs)) """
            When solving
            $eq
            $var remainded in
            $rhs.
            """
            push!(rhss, rhs)
            push!(solvars, var)
        end
        # DEBUG:
        #@show ith_scc solvars .~ rhss
        #Main._nlsys[] = eqs[e_solved], fullvars[v_solved]
        #ModelingToolkit.topsort_equations(solvars .~ rhss, fullvars)
        #empty!(solvars); empty!(rhss)
    end

    ### update SCC
    eq_reidx = Vector{Int}(undef, nsrcs(graph))
    idx = 0
    for (i, active) in enumerate(active_eqs)
        eq_reidx[i] = active ? (idx += 1) : -1
    end

    rmidxs = Int[]
    newscc = Vector{Int}[]; sizehint!(newscc, length(scc))
    for component′ in newscc
        component = copy(component′)
        for (idx, eq) in enumerate(component)
            if active_eqs[eq]
                component[idx] = eq_reidx[eq]
            else
                push!(rmidxs, idx)
            end
        end
        push!(newscc, component)
        deleteat!(component, rmidxs)
        empty!(rmidxs)
    end

    ### update graph
    var_reidx = Vector{Int}(undef, ndsts(graph))
    idx = 0
    for (i, active) in enumerate(active_vars)
        var_reidx[i] = active ? (idx += 1) : -1
    end

    newgraph = BipartiteGraph(ns, nd, Val(false))


    ### update equations
    odestats = []
    for idx in eachindex(fullvars); isdervar(s, idx) && continue
        push!(odestats, fullvars[idx])
    end
    newstates = setdiff(odestats, solvars)
    varidxmap = Dict(newstates .=> 1:length(newstates))
    neweqs = Vector{Equation}(undef, ns)
    newalgeqs = falses(ns)

    dict = Dict(value.(solvars) .=> value.(rhss))

    visited = falses(ndsts(graph))
    for ieq in Iterators.flatten(scc); active_eqs[ieq] || continue
        eq = eqs[ieq]
        ridx = eq_reidx[ieq]

        fill!(visited, false)
        compact_graph!(newgraph, graph, visited, ieq, ridx, rvar2reqs, var_reidx, active_vars)

        if isdiffeq(eq)
            neweqs[ridx] = eq.lhs ~ tearing_sub(eq.rhs, dict, simplify)
        else
            newalgeqs[ridx] = true
            if !(eq.lhs isa Number && eq.lhs == 0)
                eq = 0 ~ eq.rhs - eq.lhs
            end
            rhs = tearing_sub(eq.rhs, dict, simplify)
            if rhs isa Symbolic
                neweqs[ridx] = 0 ~ rhs
            else # a number
                if abs(rhs) > 100eps(float(rhs))
                    @warn "The equation $eq is not consistent. It simplifed to 0 == $rhs."
                end
                neweqs[ridx] = 0 ~ fullvars[invview(var_eq_matching)[ieq]]
            end
        end
    end

    ### update partitions
    newpartitions = similar(partitions, 0)
    emptyintvec = Int[]
    for (ii, partition) in enumerate(partitions)
        @unpack e_residual, v_residual = partition
        isempty(v_residual) && continue
        new_e_residual = similar(e_residual)
        new_v_residual = similar(v_residual)
        for ii in eachindex(e_residual)
            new_e_residual[ii] = eq_reidx[ e_residual[ii]]
            new_v_residual[ii] = var_reidx[v_residual[ii]]
        end
        # `emptyintvec` is aliased to save memory
        # We need them for type stability
        newpart = SystemPartition(emptyintvec, emptyintvec, new_e_residual, new_v_residual)
        push!(newpartitions, newpart)
    end

    obseqs = solvars .~ rhss

    @set! s.graph = newgraph
    @set! s.scc = newscc
    @set! s.fullvars = fullvars[active_vars]
    @set! s.vartype = s.vartype[active_vars]
    @set! s.partitions = newpartitions
    @set! s.algeqs = newalgeqs

    @set! sys.structure = s
    @set! sys.eqs = neweqs
    @set! sys.states = newstates
    @set! sys.observed = [observed(sys); obseqs]
    return sys
end

# removes the solved equations and variables
function compact_graph!(newgraph, graph, visited, eq, req, rvar2reqs, var_reidx, active_vars)
    for ivar in 𝑠neighbors(graph, eq)
        # Note that we need to check `ii` against the rhs states to make
        # sure we don't run in circles.
        visited[ivar] && continue
        visited[ivar] = true

        if active_vars[ivar]
            add_edge!(newgraph, req, var_reidx[ivar])
        else
            # If a state is reduced, then we go to the rhs and collect
            # its states.
            for ieq in rvar2reqs[ivar]
                compact_graph!(newgraph, graph, visited, ieq, req, rvar2reqs, var_reidx, active_vars)
            end
        end
    end
    return nothing
end

"""
    tearing(sys; simplify=false)

Tear the nonlinear equations in system. When `simplify=true`, we simplify the
new residual residual equations after tearing. End users are encouraged to call [`structural_simplify`](@ref)
instead, which calls this function internally.
"""
tearing(sys; simplify=false) = tearing_reassemble(tear_graph(algebraic_equations_scc(sys)); simplify=simplify)
