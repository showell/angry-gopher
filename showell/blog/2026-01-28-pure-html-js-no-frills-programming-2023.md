## Pure HTML/JS, no-frills programming (2023)

*January 28, 2026*

Every now and then it's fun to build a simple
but not totally trivial app (multiple modules)
without any kind of build process.

The code from my [table_widget repo](https://github.com/showell/table_widget) avoids so many moving parts:
* no webpack
* no compilers or transpilers
* no jQuery or third party libraries
* no frameworks
* no templates
* no external CSS files

Don't get me wrong, it's a pretty small and
unimpressive project.  I just wanted to build
some table widgets that look like this:

![tables](tables.png)

You can see the whole program in action
[here](https://showell.github.io/table_widget/).

The project has exactly one HTML file called
`index.html`:

``` html
<!DOCTYPE html>
<head>
    <title>Table Widget</title>
    <style>
        body {
            padding-top: 50px;
        }

        #app {
            display: flex;
            justify-content: space-evenly;
        }

        #even_numbers {
            display: flex;
            flex-direction: column;
    </style>

</head>
<body>
    <div id="app">
        <div id="fruits"></div>
        <div id="persons"></div>
        <div id="prime_squares"></div>
        <div id="even_numbers"></div>
    </div>
</body>
<script src="./data_helpers.js"></script>
<script src="./style_helpers.js"></script>
<script src="./dom_helpers.js"></script>
<script src="./table_helpers.js"></script>
<script src="./integer_table_helper.js"></script>
<script src="./single_column_table_helper.js"></script>
<script src="./table.js"></script>
```

And then all the JS files use the same structure to
"export" their namespaces right on to the `window`
object.

Here is `table_helpers.js`:

``` js
window.table_helpers = (function () {
    const { dom_empty_table } = window.dom_helpers;

    const { setStyles } = window.style_helpers;
    console.log("YO", setStyles);

    function list_renderer({ parent_elem, make_child, get_num_rows }) {
        function overwrite(i, elem) {
            console.log("overwrite", i);
            if (i >= parent_elem.children.length) {
                parent_elem.append(elem);
            } else {
                parent_elem.replaceChild(elem, parent_elem.children[i]);
            }
        }

        function is_child_too_far_down(i) {
            // TODO: integrate once I guarantee tables get wrapped in a scroll
            // container early enough.
            const scroll_container = parent_elem.closest(
                ".table_scroll_container"
            );
            const child_top =
                parent_elem.children[i].getBoundingClientRect().top;
            const container_bottom =
                scroll_container.getBoundingClientRect().bottom;
            console.log(Math.floor(child_top), Math.floor(container_bottom));

            return child_top > container_bottom;
        }

        function repopulate_range(lo, hi) {
            for (let i = lo; i < hi; ++i) {
                overwrite(i, make_child(i));
            }
        }

        function compress(num_rows) {
            for (let i = parent_elem.children.length - 1; i >= num_rows; --i) {
                parent_elem.children[i].remove();
            }
        }

        function repopulate() {
            const num_rows = get_num_rows();
            compress(num_rows);
            repopulate_range(0, num_rows);
        }

        function resize_list() {
            /*
                The contract here is that none of the existing data elements
                have changed.
            */
            const num_rows = get_num_rows();
            compress(num_rows);
            repopulate_range(parent_elem.children.length, num_rows);
        }

        return { resize_list, repopulate };
    }

    function wrap_table(table, maxHeight) {
        const div = document.createElement("div");

        div.className = "table_scroll_container";

        setStyles(div, {
            display: "inline-block",
            overflowY: "scroll",
            maxHeight,
        });

        div.append(table);
        return div;
    }

    function simple_table_widget({
        make_header_row,
        make_tr,
        get_num_rows,
        maxHeight,
    }) {
        function resize_list() {
            console.log("resize_list", table.id);
            my_renderer.resize_list();
        }

        function repopulate() {
            console.log("repopulate", table.id);
            my_renderer.repopulate();
        }

        const { table, thead, tbody } = dom_empty_table();

        thead.append(make_header_row());

        // It is important to wrap the table with a scrolling container
        // BEFORE you start rendering the list of rows.

        const scroll_container = wrap_table(table, maxHeight);

        const my_renderer = list_renderer({
            parent_elem: tbody,
            make_child: make_tr,
            get_num_rows,
        });

        repopulate();

        return { scroll_container, table, repopulate, resize_list };
    }

    function wire_up_reverse_button({ th, callback }) {
        const button = document.createElement("button");
        button.innerText = "reverse";
        button.addEventListener("click", callback);
        th.append("  ", button);
    }

    return {
        simple_table_widget,
        wire_up_reverse_button,
    };
})();
```

The outer structure is like so:

``` js
window.table_helpers = (function () {

    // ...

    return {
        simple_table_widget,
        wire_up_reverse_button,
    };
})();
```

That exports the functions `simple_table_widget`
and `wire_up_reverse_button` on to `windows.table_helpers`.

And then that same code emulates imports like so:

``` js
    const { dom_empty_table } = window.dom_helpers;
    const { setStyles } = window.style_helpers;
```

For a small project like this, it's pretty easy to manage
naming collisions. Just use the same names for your
`window.foo` "exports" as the file names itself. And don't
use any names that are obviously on `window` itself.

There's a variation of this pattern that's only slightly
heavier. You can be sure that you only add `window.APP` to
`window` in the HTML file (right before you pull in the
JS files).  And then say `window.APP.table_helpers = ...`
instead of `window.table_helpers = ...`.

I don't claim this programming pattern is completely
necessary or even highly recommended.  You can certainly
use webpack. But it's nice to know the minimal approaches
too.

I also write directly to the browser DOM API. Here's
a lightweight set of helpers that I created for the
project (`dom_helpers.js`), but these are all just minimal
ES6 sugar on top of the regular DOM API. The DOM API
is tried-and-true!

``` js
window.dom_helpers = (function () {
    const { setStyles } = window.style_helpers;

    function dom_empty_table() {
        const table = document.createElement("table");
        const thead = document.createElement("thead");
        table.append(thead);

        const tbody = document.createElement("tbody");
        table.append(tbody);

        return { table, thead, tbody };
    }

    function dom_tr(...child_elems) {
        const tr = document.createElement("tr");
        tr.append(...child_elems);
        return tr;
    }

    function dom_td({ id, elem }) {
        const td = document.createElement("td");
        td.id = id;
        td.append(elem);
        return td;
    }

    function maybe_stripe(elem, i, color) {
        if (i % 2) {
            setStyles(elem, {
                background: color,
            });
        }

        return elem;
    }

    return {
        dom_empty_table,
        dom_tr,
        dom_td,
        maybe_stripe,
    };
})();
```
