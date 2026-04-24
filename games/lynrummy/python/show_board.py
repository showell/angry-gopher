"""Pretty-print a board: one line per stack, space-separated
card labels like 5H, 8C, JS, AD."""

import dsl_player


def show(board):
    for s in board:
        labels = [dsl_player._label(bc["card"])
                  for bc in s["board_cards"]]
        print(" ".join(labels))


if __name__ == "__main__":
    import test_d1_d2_sweep as ts
    show(ts.build_d1_board_all_pure())
