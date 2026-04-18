## A day in the life

I occasionally keep notes on what I do during the day. The
process of taking notes sometimes keeps you focused. It also
lets you measure where the time went.

#### early, early morning

I woke up at 5am, but for the first two hours of the morning,
I really wasn't super productive.  I was mostly drinking
coffee, getting caught up on chats, and planning my day.

I don't feel too bad about that, since I was able to still
hit the ground running at 7am.

#### early morning (7am - 10am)

My only real coding task yesterday was to spend the morning
adding a feature to my Lyn Rummy card game.

I now keep score during the turn.

``` diff
commit 90505e3e18e8c0db00535a25be57be010f5e57d1
Author: Steve Howell <showell30@yahoo.com>
Date:   Tue Feb 24 09:58:40 2026 -0500

    Give improved feedback for scoring.

diff --git a/game.ts b/game.ts
index df4ca74..3c5479c 100644
--- a/game.ts
+++ b/game.ts
@@ -923,6 +923,7 @@ class Player {
     hand: Hand;
     num_drawn: number;
     total_score: number;
+    total_score_when_turn_started: number;
     player_turn?: PlayerTurn;

     constructor(name: string) {
@@ -932,6 +933,7 @@ class Player {
         this.num_drawn = 0;
         this.hand = new Hand();
         this.total_score = 0;
+        this.total_score_when_turn_started = 0;
     }

     get_turn_score(): number {
@@ -939,7 +941,16 @@ class Player {
         return this.player_turn.get_score();
     }

+    get_updated_score(): number {
+        if (CurrentBoard.is_clean() && this.player_turn && this.active) {
+            this.total_score =
+                this.total_score_when_turn_started + this.get_turn_score();
+        }
+        return this.total_score;
+    }
+
     start_turn(): void {
+        this.total_score_when_turn_started = this.total_score;
         this.show = true;
         this.active = true;
         this.num_drawn = 0; // only used after end_turn
@@ -970,10 +981,10 @@ class Player {
                 break;
         }

-        this.active = false;
+        // Make sure that the total score is current.
+        this.get_updated_score();

-        // Finally bump up the player's overall score.
-        this.total_score += this.get_turn_score();
+        this.active = false;

         return turn_result;
     }
@@ -1041,7 +1052,7 @@ class ScoreSingleton {
     stack_type_value(stack_type: CardStackType): number {
         switch (stack_type) {
             case CardStackType.PURE_RUN:
-                return 90;
+                return 100;
             case CardStackType.SET:
                 return 60;
             case CardStackType.RED_BLACK_RUN:
@@ -1066,7 +1077,10 @@ class ScoreSingleton {
     }

     for_cards_played(num: number) {
-        return 100 * num * num;
+        if (num === 0) return 0;
+        const actually_played_bonus = 200;
+        const progressive_points_for_played_cards = 100 * num * num;
+        return actually_played_bonus + progressive_points_for_played_cards;
     }
 }

@@ -2066,7 +2080,7 @@ class PhysicalPlayer {
     score(): HTMLElement {
         const div = document.createElement("div");

-        const score = this.player.total_score;
+        const score = this.player.get_updated_score();

         div.innerText = `Score: ${score}`;
         div.style.color = "maroon";
@@ -2382,7 +2396,7 @@ class EventManagerSingleton {

     undo_mistakes(): void {
         TheGame.rollback_moves_to_last_clean_state();
-        StatusBar.inform("PHEW!");
+        StatusBar.inform("We restored the game to its last clean state.");
         DragDropHelper.reset_internal_data_structures();
         PlayerArea.populate();
         BoardArea.populate();
@@ -2390,8 +2404,8 @@ class EventManagerSingleton {

     split_stack(player_action: PlayerAction): void {
         TheGame.process_player_action(player_action);
-        StatusBar.inform(
-            "Split! Moves like this can be tricky, even for experts. You have the undo button if you need it.",
+        StatusBar.scold(
+            "Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles.",
         );
     }
```

That fairly simple diff took me about three hours to knock out,
mostly because of debugging and testing. It's a little tricky
during a game to handle scoring logic as you change turns from
one player to the next. It's not rocket science, but if you do
something like unset an "active" flag too early, it can mess
with the proper of sequence of operations and lead to incorrect
scores.

It had been a couple weeks since I had made any non-trivial
changes to the codebase. It was pretty easy to dive right back
in.  I started by taking notes of how the current scoring
worked.  Once I did that, it was mostly straigthforward to
add another instance variable to keep track of the total
score at the beginning of the turn.

I made a couple other small changes in passing.

The three hours did represent clock time, not focused time.
During that time I was still doing my morning routine, such
as driving to the kava shop and watching some YouTube.

#### writing (mentoring)

I spent the rest of the day writing.

I first completed my blog entry on "Mentoring Aproova". I
had no real momentum on that article, so it just kinda fizzled.
I probably spent about three hours on getting the last couple
sections written, and most of that was trying to pshyche
myself up.

#### writing (Angry Cat)

I then decide to blog about the Angry Cat, and that was a
real "flow" writing session.  But it was a lot of work.
I wanted lots of screenshots and screencasts, and that whole
process isn't very automated (or easy to automate as far
as I know).

I was also pulling lots of code excerpts.

It was kind of a good exercise for me to see which pieces
of the architecture I wanted to emphasize.  I actually like
the entire codebase at this point. It would be interesting
to see what Claude could do with it.

#### summary

For a day in which I wrote almost no code, I till felt
somewhat productive. I am slowly fleshing out the blog,
so that feels good. I would give the whole day about a
B- in terms of how much I enjoyed it, how much energy
I felt, and the outcome of my work.

*February 25, 2026*
