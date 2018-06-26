using Flux, CuArrays
using BSON:@save
using Flux:params
using OpenAIGym
import Reinforce:action
import Base: deepcopy

# ------------------------ Load game environment -------------------------------
env = GymEnv("Pong-v0")

# Custom Policy for Pong-v0
mutable struct PongPolicy <: Reinforce.AbstractPolicy
  prev_state
  train::Bool
  function PongPolicy(train = true)
    new(zeros(STATE_SIZE), train)
  end
end

# ---------------------------- Parameters --------------------------------------

STATE_SIZE = 6400 #length(env.state)
ACTION_SPACE = 2 #length(env.actions)
MEM_SIZE = 1000000
BATCH_SIZE = 64
REPLAY_START_SIZE = 50000
UPDATE_FREQ = 500
γ = 0.99    # discount rate

# Exploration params
ϵ_START = 1.0   # Initial exploration rate
ϵ_STOP = 0.1    # Final exploratin rate
ϵ_STEPS = 10000   # Final exploration frame, using linear annealing

# Optimiser params
η = 2.5e-4   # Learning rate
ρ = 0.95    # Gradient momentum for RMSProp

memory = [] #used to remember past results
frames = 1
C = 0

# --------------------------- Model Architecture -------------------------------
struct nn
  base
  value
  adv
  opt

  function nn(base, value, adv)
    all_params = vcat(params(base), params(value), params(adv))
    opt =  RMSProp(all_params, η; ρ = ρ)
    new(base, value, adv, opt)
  end
end

function (m::nn)(inp)
  Q(x::TrackedArray) = m.value(x) .+ m.adv(x) .- mean(m.adv(x), 1)
  Q(m.base(inp))
end

function deepcopy(m::nn)
  nn(deepcopy(m.base), deepcopy(m.value), deepcopy(m.adv))
end

base = Chain(Dense(STATE_SIZE, 200, relu)) |> gpu
value = Dense(200, 1, relu) |> gpu
adv = Dense(200, ACTION_SPACE, relu) |> gpu

model = nn(base, value, adv)

model_target = deepcopy(model)

huber_loss(x, y) = mean(sqrt.(1 + (model(x) - y) .^ 2) - 1)

fit_model(data) = Flux.train!(huber_loss, data, model.opt)

# ------------------------------- Helper Functions -----------------------------

get_ϵ() = steps == ϵ_STEPS ? ϵ_STOP : ϵ_START + steps * (ϵ_STOP - ϵ_START) / ϵ_STEPS

function save_model(model::nn)
  base_wt = cpu.(Tracker.data.(params(model.base)))
  val_wt = cpu.(Tracker.data.(params(model.value)))
  adv_wt = cpu.(Tracker.data.(params(model.adv)))

  @save "../models/duel_dqn_base" base_wt
  @save "../models/duel_dqn_val" val_wt
  @save "../models/duel_dqn_adv" adv_wt
  
  println("Model saved")
end

function preprocess(I)
  #= preprocess 210x160x3 uint8 frame into 6400 (80x80) 1D float vector =#
  I = I[36:195, :, :] # crop
  I = I[1:2:end, 1:2:end, 1] # downsample by factor of 2
  I[I .== 144] = 0 # erase background (background type 1)
  I[I .== 109] = 0 # erase background (background type 2)
  I[I .!= 0] = 1 # everything else (paddles, ball) just set to 1

  return I[:] #Flatten and return
end

# Putting data into replay buffer
function remember(prev_s, s, a, r, s′, done)
  if length(memory) == MEM_SIZE
    deleteat!(memory, 1)
  end

  state = preprocess(s) - prev_s
  next_state = env.done ? zeros(STATE_SIZE) : preprocess(s′)
  next_state = next_state - preprocess(s)
  r = clamp(r, -1, 1)
  push!(memory, (state, a, r, next_state, done))
end

function action(π::PongPolicy, reward, state, action)
  if rand() <= get_ϵ() && π.train
    return rand(1:ACTION_SPACE) + 1 # UP and DOWN action corresponds to 2 and 3
  end

  s = preprocess(state) - π.prev_state |> gpu
  act_values = model(s)
  return Flux.argmax(act_values) + 1  # returns action max Q-value
end

function replay()
  global C, model_target

  minibatch = sample(memory, BATCH_SIZE, replace = false)
  x = zeros(STATE_SIZE, BATCH_SIZE)
  y = zeros(ACTION_SPACE, BATCH_SIZE)
  i = 1
  for (state, action, reward, next_state, done) in minibatch
    target = reward

    if !done
      a_max = Flux.argmax(model(next_state |> gpu))
      target += γ * model_target(next_state |> gpu).data[a_max]
    end

    target_f = model(state |> gpu).data
    target_f[action] = target

    x[:, i] .= state
    y[:, i] .= target_f

    #dataset = zip(cu(state), cu(target_f))
    #fit_model(dataset)

    C = (C + 1) % UPDATE_FREQ
    i += 1
  end
  loss = huber_loss(cu(x), cu(y))
  Flux.back!(loss)
  model.opt()
  # Update target model
  if steps % UPDATE_FREQ == 0
    model_target = deepcopy(model)
    save_model(model)
  end

  return loss.tracker.data
end

function episode!(env, π = RandomPolicy())
  global frames
  ep = Episode(env, π)

  for (s, a, r, s′) in ep
    #OpenAIGym.render(env)
    if π.train remember(π.prev_state, s, a - 1, r, s′, env.done) end
    π.prev_state = preprocess(s)
    frames += 1
  end

  ep.total_reward
end

# ------------------------------ Training --------------------------------------

e = 1
steps = 0
while steps < ϵ_STEPS
  reset!(env)
  total_reward = episode!(env, PongPolicy())
  eps = get_ϵ()
  loss = 0
  if frames >= REPLAY_START_SIZE
    loss = replay()
    steps += 1
  end
  println("Episode: $e | Score: $total_reward | eps: $eps | loss: $loss | steps: $steps")
  e += 1
end
#=
# -------------------------------- Testing -------------------------------------
ee = 1

while true
  reset!(env)
  total_reward = episode!(env, PongPolicy(false))
  println("Episode: $ee | Score: $total_reward")
  ee += 1
end=#
