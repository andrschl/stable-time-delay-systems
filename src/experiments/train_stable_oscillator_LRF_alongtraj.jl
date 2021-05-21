## Hyperparameters
config = Dict(
    # on server?
    "server" => false,

    # ground truth dynamics
    "ω" => 1.0,
    "γ" => 0.01,

    # ndde training
    "θmax_train" => 0.5,
    "θmax_test" => 10.0,
    "ntrain_trajs" => 1,
    "ntest_trajs" => 10,
    "T_train" => 3*pi,
    "T_test" => 40*pi,
    "datasize" => 30,
    #"Δt_data" => 0.4,
    "batchtime" => 30,
    "batchsize" => 1,
    "const_init" => false,

    # ndde model
    "Δtf" => 0.3,
    "rf" => 3.0,

    # lr schedule
    "lr_rel_decay" => 0.01,
    "lr_start_max" => 5e-3,
    "lr_start_min" => 1e-4,
    "lr_period" => 100,
    "nepisodes" => 200,

    # stabilizing training
    "θmax_lyap" => 10.0,
    "nlyap_trajs" => 10,
    "T_lyap" => 30,
    "batchsize_lyap" => 256,
    "nacc_steps_lyap" => 1,
    "uncorrelated" => true,
    "uncorrelated_data_size" => 100000,
    "resample" = true,


    # lyapunov loss
    "Δtv" => 0.3,
    "rv" => 6.0,
    "α" => 0.01,
    "q" => 1.01,
    "weight_f" => 0.1,
    "weight_v" => 0.1,
    "warmup_steps" => 10,

    # logging
    "test_eval" => 20,
    "model checkpoint" => 500
)

## some server specific stuff..
if config["server"]
    ENV["GKSwstype"] = "nul"
end
## Load packages
cd(@__DIR__)
cd("../../.")
using Pkg; Pkg.activate("."); Pkg.instantiate();
using PyCall
include("../util/import.jl")
using GaussianProcesses
# using AbstractGPs
## seeding
seed = 1
if length(ARGS) >= 1
    seed = parse(Int64, ARGS[1])
end
if length(ARGS) >= 2
    config["σ"] = parse(Float64, ARGS[2])
end
if length(ARGS) >= 3
    config["weight_f"] = parse(Float64, ARGS[3])
end
if length(ARGS) >= 4
    config["weight_v"] = parse(Float64, ARGS[4])
end
if length(ARGS) >= 5
    config["grad_clipping"] = parse(Float64, ARGS[5])
end

## log path
project_name = "stable_osc_LKF_alongtraj"
runname = "seed_"*string(seed)
configname = string(config["σ"])*"/"*string(config["weight_f"])*"/"*string(config["weight_v"])*"/"*string(config["grad_clipping"])*"/"
devicename = config["server"] ? "server_" : "blade_"
logpath = "reports/"*project_name*"/seed_"*string(seed)*"/"
println(logpath)
println(configname)
mkpath(logpath)
if config["logging"]
    wandb = pyimport("wandb")
    # wandb.init(project=splitext(basename(@__FILE__))[1], entity="andrschl", config=config, name=runname)
    wandb.init(project=project_name, config=config, name=runname, group=devicename*configname)
end

## set seed
Random.seed!(123)
rng = MersenneTwister(1234)

## Load pendulum dataset
include("../datasets/stable_oscillator.jl")

config["Δt_data"] = config["T_train"]/config["datasize"]

# initial conditions
distr_train = Uniform(-config["θmax_train"], config["θmax_train"])
distr_test = Uniform(-config["θmax_test"], config["θmax_test"])
distr_lyap = Uniform(-config["θmax_lyap"], config["θmax_lyap"])

# ICs_train = map(i-> vcat(rand(rng, distr_train, 2)), 1:config["ntrain_trajs"])
# ICs_test = map(i-> vcat(rand(rng, distr_test, 2)), 1:config["ntest_trajs"])
ICs_train = map(i-> [rand(distr_train, 1)[1],0.0], 1:config["ntrain_trajs"])
ICs_test = map(i-> [rand(distr_test, 1)[1],0.0], 1:config["ntest_trajs"])
ICs_lyap = map(i-> vcat(rand(rng, distr_lyap, 1)), 1:config["nlyap_trajs"])
h0s_lyap = map(u0 -> (p,t) -> u0, ICs_lyap)


tspan_train = (0.0, config["T_train"])
tspan_lyap = (0.0,config["T_lyap"] )
tspan_test = (0.0, config["T_test"])

df_train = DDEODEDataset(ICs_train, tspan_train, config["Δt_data"], oscillator_prob, config["rf"]; obs_ids=[1])
df_test = DDEODEDataset(ICs_test, tspan_test, config["Δt_data"], oscillator_prob, config["rf"]; obs_ids=[1])

gen_dataset!(df_train)
Random.seed!(122+seed)
gen_noise!(df_train, 0.2)
gen_dataset!(df_test)
gen_noise!(df_test, 0.2)

## Define model
include("../models/model.jl")
data_dim = 1
flags = Array(config["Δtf"]:config["Δtf"]:config["rf"])
vlags = Array(config["Δtv"]:config["Δtv"]:config["rv"])
Random.seed!(seed)
model = RazNDDE(data_dim; flags=flags, vlags=vlags, α=config["α"], q=config["q"])
pf = model.pf
pv = model.pv

## Define model dataset for lyapunov training

if !config["uncorrelated"]
    lyap_prob = DDEProblem(model.ndde_func!, ICs_lyap[1],h0s_lyap[1], tspan_lyap, constant_lags=flags)
    df_model = DDEDDEDataset(h0s_lyap, tspan_lyap, min(config["Δtv"],config["Δtf"]), lyap_prob, max(config["rv"],config["rf"]), flags)
    gen_dataset!(df_model, p=model.pf)
    lyap_loader = Flux.Data.DataLoader(df_model, batchsize=config["batchsize_lyap"], shuffle=true)
else
    data = hcat(map(i-> rand(distr_lyap, 2*data_dim*(length(vlags)+1)), 1:config["uncorrelated_data_size"])...)
    lyap_loader = Flux.Data.DataLoader((Array(1:config["uncorrelated_data_size"]),data), batchsize=config["batchsize_lyap"],shuffle=true)
end
## Define model dataset for lyapunov training

if !config["uncorrelated"]
    lyap_prob = DDEProblem(model.ndde_func!, ICs_lyap[1],h0s_lyap[1], tspan_lyap, constant_lags=flags)
    df_model = DDEDDEDataset(h0s_lyap, tspan_lyap, min(config["Δtv"],config["Δtf"]), lyap_prob, max(config["rv"],config["rf"]), flags)
    gen_dataset!(df_model, p=model.pf)
    lyap_loader = Flux.Data.DataLoader(df_model, batchsize=config["batchsize_lyap"], shuffle=true)
else
    data = hcat(map(i-> rand(rng, distr_lyap, 2*data_dim*(length(vlags)+1)), 1:config["uncorrelated_data_size"])...)
    lyap_loader = Flux.Data.DataLoader((Array(1:config["uncorrelated_data_size"]),data), batchsize=config["batchsize_lyap"],shuffle=true)
end
# iterate(lyap_loader)
## training
include("../training/training_util.jl")

@time begin
    rel_decay, locmin, locmax, period = config["lr_rel_decay"], config["lr_start_min"], config["lr_start_max"], config["lr_period"]
    lr_args = (rel_decay, locmin, locmax, period)
    lr_kwargs = Dict(:len => config["nepisodes"])
    lr_schedule_gen = double_exp_decays
    lr_schedule = lr_schedule_gen(lr_args...;lr_kwargs...)
    pf = model.pf
    pv = model.pv
    for (lr, iter) in lr_schedule
        println("==============")
        println("iter: ", iter)
        # get ndde batch
        optf = ADAM(lr)
        optv=optf
        ts, batch_u, batch_h0 = get_ndde_batch_and_h0(df_train, batchtime, batchsize)
        batch_t = ts[:,1].-ts[1,1]
        # get lyapunov data
        global lyap_loader
        if !config["uncorrelated"]
            gen_dataset!(df_model, p=pf)
            lyap_loader = Flux.Data.DataLoader(df_model, batchsize=config["batchsize_lyap"], shuffle=true)
        end

        # combined train step
        kras_stable_ndde_train_step!(batch_u[:,1,:], batch_u, batch_h0, pf, pv, batch_t, model, optf, optv, iter, lyap_loader)
        # test evaluation
        if iter % config["test_eval"] == 0
            # log train fit first trajectory
            wandb_plot_ndde_data_vs_prediction(df_train, 1, model, pf, "train fit 1")

            test_losses = []
            for i in 1:config["ntest_trajs"]
                t_test = df_test.trajs[i][1][df_test.N_hist:end]
                u_test = hcat(df_test.trajs[i][2][df_test.N_hist:end]...)
                u0_test = u_test[:,1]
                h0_test = (p,t) -> df_test.trajs[i][3](t)
                test_loss, _ = predict_ndde_loss(u0_test, h0_test, t_test, u_test, pf, model; N=df_test.N)
                push!(test_losses, test_loss)
                # if !params["server"]
                #     test_sol = dense_predict_ndde(u0_test, h0_test, tspan_test, pf, model)
                #     pl = plot(test_sol, xlims=tspan_test, title="Generalization traj " * string(i))
                #     scatter!(pl, t_test, u_test[1,:], label="θ_true1")
                #     scatter!(pl, t_test, u_test[2,:], label="θ_true2")
                #     scatter!(pl, t_test, u_test[3,:], label="θ_true3")
                #     display(pl)
                # end
                wandb_plot_ndde_data_vs_prediction(df_test, i, model, pf, "test fit "*string(i))
            end
            wandb.log(Dict("test loss"=> sum(test_losses)/config["ntest_trajs"]))
        end
        if iter % config["model checkpoint"] == 0
            filename = logpath * "weights-" * string(iter) * ".bson"
        end
    end
end

# Logging a custom table of data
mkpath(logpath*"figures/")

# Final plots
wandb_plot_ndde_data_vs_prediction(df_test, 1, model, pf, "test fit 1")
wandb_plot_ndde_data_vs_prediction(df_train, 1, model, pf, "train fit 1")

# save params
using BSON: @save
filename_f = logpath * "weights_f.bson"
filename_v = logpath * "weights_v.bson"
@save filename_f pf
@save filename_v pf
