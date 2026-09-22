---
title: "Writing a model in prose"
description: "A tutorial: define, test and plot a model inside the page that explains it."
weight: 10
---

A narrative page defines its model as it explains it. The mathematics you read
below, the test result, and the figures are all produced from the same
declarations — there is no second copy of the model to keep in step, and the
page fails to build if the model does not.

## A first model

::model[Decay]{description="First-order radioactive decay"}

Start with radioactive decay. A sample holds an amount of nitrogen,
:var[N]{default=100 units="mol" description="Amount of nitrogen"}, which decays
at a rate proportional to how much is left. The constant of proportionality is
the decay constant :param[lambda]{default=0.1 units="1/s" description="Decay constant"}:

::eq[D(N, t) = -lambda*N]{#eq-decay}

That is the whole model. `D(N, t)` is the text syntax for the derivative of
\(N\) with respect to time, and every name in the equation has to be declared
somewhere on the page, or the build stops and points at the equation.

::esm-variables{}

## Checking it

The solution of [the decay equation](#eq-decay) is \(N(t) = N_0 e^{-\lambda t}\),
so after one half-life, \(t = \ln 2 / \lambda\), half of the sample is left. A
test says so, and the build runs it:

:::esm-test{#half-life span="0..10"}
assertions:
  - variable: N
    time: 6.931471805599453
    expected: 50
    tolerance: {rel: 0.0001}
:::

## Drawing it

A figure is a plot with a time span and something to show on its y axis. This
one runs the model for fifty seconds:

:::esm-plot{#decay span="0..50" y=N}
description: The sample decays to about 0.7% of its initial amount in 50 s.
:::

Sweeping a parameter draws one line per value, which is how you show what a
parameter does:

:::esm-plot{#rates span="0..50" y=N}
description: Faster decay constants empty the sample sooner.
parameter_sweep:
  type: cartesian
  dimensions:
    - parameter: lambda
      values: [0.05, 0.1, 0.2]
:::

## Two boxes

A model with more than one state variable is no harder. Two reservoirs exchange
mass, and nothing leaves the pair:

::model[TwoBox]{description="Two well-mixed boxes exchanging mass"}

Box A holds :var[A]{default=1 units="mol" description="Mass in box A"} and box B
holds :var[B]{default=0 units="mol" description="Mass in box B"}. Mass moves
from A to B at rate :param[k_ab]{default=0.3 units="1/s" description="Transfer rate, A to B"}
and back at rate :param[k_ba]{default=0.1 units="1/s" description="Transfer rate, B to A"}:

::eq[D(A, t) = k_ba*B - k_ab*A]{#eq-a}

::eq[D(B, t) = k_ab*A - k_ba*B]{#eq-b}

At equilibrium the two flows balance, so \(B = k_{ab} / (k_{ab} + k_{ba})\),
which is 0.75 for these rates:

:::esm-test{#equilibrium span="0..100"}
assertions:
  - variable: B
    time: 100
    expected: 0.75
    tolerance: {rel: 0.001}
:::

:::esm-plot{#boxes span="0..20"}
description: Mass moves from A to B until the two flows balance.
y: [A, B]
:::

An analysis runs the model many times and reduces each run to one number. This
one sweeps both rate constants and reports where the mass ends up:

:::esm-analysis{#rates span="0..100"}
parameter_sweep:
  type: cartesian
  dimensions:
    - parameter: k_ab
      range: {start: 0.1, stop: 1, count: 8}
    - parameter: k_ba
      range: {start: 0.01, stop: 1, count: 8, scale: log}
plots:
  - id: final_B
    type: heatmap
    description: The share of mass in box B at equilibrium, over both rate constants.
    x: {variable: k_ab}
    y: {variable: k_ba}
    value: {variable: B, reduce: final}
:::

::esm-variables{model=TwoBox}

## The file behind the page

Everything above is one `.esm` document, which you can read, run or import like
any other:

::esm-download{}
