## LIQUIDTY BET HOOK

The general idea is that a user can achieve something like "I bet X amount of ETH that liquidity from pool Token0/Token1 is gonna be higher/lower than the current liquidity once the betting round finishes", having always the option to cashout at any time of the betting round.

# Concepts - Definitions

1. What is the betting round?
   It is the timeframe where the users can place a bet. In the hook is set to 24 hours. Every 24 hours a snapshot is taken and starts another bet round.

2. How a user can place a bet?
   To place a bet the user have to call the payable placeOrder method with the pool key. the side (SHORT/LONG) and the amount he wants to place in ETH. Betting only with ETH is a really good advantage because the entry barrier is minimum. You dont force the user to swap tokens to bet to a specific pool. Because ... who doesnt have ETH using Uniswap? 🤗

When the user places an order, a position token is minted storing the pool key, the bet amount, the side, the current liquidity of the pool and the current betting round (a timestamp). This one we can identify in the cashout/redeem methods if a user have a winning position or not.

3. Why the betting round is 24 hours?
   This is a preventive barrier to avoid critical manipulations from LP.
   Example: I bet that liquidity is gonna be higher/lower, then i add/remove liquidity and game over, i always win :)

We all know that manipulation is gonna always be around, and is part of this industry, BUT the idea of having a 24 hours timeframe is allowing manipulate to everyone!

4. What happens when a betting round finished?
   First of all, the hook takes a snapshot of the current liquidity for the specific pool. Once this snapshot is done, the winning positions can start redeem their % from the jackpot in ETH. The more you bet, the more you can reedem.

5. Why the user has to bet for the current liquidity?
   This is another preventive barrier. Placing the bet having into account the current liquidity, you have 50% chance to win.
   Example: I bet liquidity is gonna be higher than 1. You are gonna always win. On the other side, if you force the user to bet with the current liquidity they have the same change to win than to lose.

6. How the cashout works?
   To calculate the cashout we have 2 variables into account: the betState and the timeFration.

_betstate_: (from 0 - 1). Having 1 a winning bet, having 0 a losing bet.
_timeFration_: The % of time from the beginning of the betting round. Having 0 as the beginning and 0,99 about to finished the betting round.

First of all we calcule the cashoutPercetage following the f(x)=-x^(2)+1 formula. This curve punishes more the cashouts closer to the end of the betting round.

The total amount to cashout will be: (cashoutPercetage \* betstate) - 1% for the winning positions.

# Challenges

- Challenge 1: Avoid High Manipulation from LPs
  To address this, I introduced a 24-hour betting round, allowing other participants to bet against manipulative actions.

- Challenge 2: Avoid High Manipulation from Traders
  Initially, I considered allowing users to specify an exact liquidity amount. However, this approach would enable users to guarantee a win by placing a long order with a minimal liquidity amount like 1. This is why I decided to use the current liquidity as the basis for user bets. This way, users have an equal chance of winning or losing.

- Challenge 3: Cashout Formula
  I wanted to simulate as max the behaviour of a cashout you could find in any sport betting website without overcomplicating the process and risking the jackpot. This is why I opted for a straightforward formula where the maximum jackpot amount is the bet amount minus 1% for winning positions.

In sports betting, both the bet state and the remaining time are considered. I wanted to implement a similar approach.

To calculate the bet state, I used a simple equation: if it's a winning position, the state is 1; otherwise, it is the distance between the winning liquidity and the bet liquidity.

For the cashout percentage, I experimented with different curves and found that -x^2+1 was the most appropriate.

- Challenge 4: Run Complexity
  Finally, all functionality is designed to achieve a maximum complexity of O(1), avoiding any loops.

# What inspired you to build it?

First of all I wanted to build some perp hook to attract more liquidity to the protocol, but by building the hook some ideas came up ending up in this idea that matches my objectives in this cohort.
