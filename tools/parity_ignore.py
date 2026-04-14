"""Known-deliberate divergences between Go and Elm twin modules.

parity_check.py subtracts these before reporting drift. Add a short
comment above each entry explaining WHY it's deliberate — this file
doubles as the record for future-us.

Populate collaboratively with Steve — don't silence drift without
understanding it.
"""

IGNORE = {
    "card": {
        "go_only": [],
        "elm_only": [],
    },
    "stack_type": {
        "go_only": [],
        "elm_only": [],
    },
    "card_stack": {
        "go_only": [],
        "elm_only": [],
    },
    "board_geometry": {
        "go_only": [],
        "elm_only": [],
    },
    "referee": {
        "go_only": [],
        "elm_only": [],
    },
}
