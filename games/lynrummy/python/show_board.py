"""Pretty-print a board: one line per stack, space-separated
card labels like 5H, 8C, JS, AD."""


def _label(c):
    rank = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}.get(
        c["value"], str(c["value"]))
    suit = {0: "C", 1: "D", 2: "S", 3: "H"}.get(c["suit"], "?")
    return f"{rank}{suit}"


def show(board):
    for s in board:
        labels = [_label(bc["card"]) for bc in s["board_cards"]]
        print(" ".join(labels))
