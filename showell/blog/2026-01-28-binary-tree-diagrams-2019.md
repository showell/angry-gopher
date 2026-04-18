## Binary Tree Diagrams (2019)

*January 28, 2026*

Sometimes it is fun to just write code that draws pretty
pictures:

![Binary Tree Diagram](binary-tree-diagram.png)

You can see this in action
[here](https://showell.github.io/binary-tree-diagram.html).

This was a program I wrote back in 2019, using the Elm
Programming language.

It uses Elm's `Svg` code under the hood.

You can see all the code at
[my binary-tree-diagram repo](https://github.com/showell/binary-tree-diagram),
but here's a taste of the code:

``` elm
    drawCoordNode : CoordNode v -> Html msg
    drawCoordNode coordNode =
        let
            ( cx, cy, r ) =
                coordNode.coord

            fontSize =
                r * 0.7

            strokeWidth =
                r / 30.0

            fill =
                getNodeColor coordNode.data

            circle =
                Svg.circle
                    [ Svg.Attributes.cx (String.fromFloat cx)
                    , Svg.Attributes.cy (String.fromFloat cy)
                    , Svg.Attributes.r (String.fromFloat r)
                    , Svg.Attributes.fill fill
                    ]
                    []

            text =
                getNodeText coordNode.data

            textAnchor =
                "middle"

            textFill =
                "white"

            x =
                cx

            y =
                cy + (fontSize / 4)

            label =
                Svg.text_
                    [ Svg.Attributes.x (String.fromFloat x)
                    , Svg.Attributes.y (String.fromFloat y)
                    , Svg.Attributes.fontSize (String.fromFloat fontSize)
                    , Svg.Attributes.fill textFill
                    , Svg.Attributes.strokeWidth (String.fromFloat strokeWidth)
                    , Svg.Attributes.textAnchor textAnchor
                    ]
                    [ Svg.text text
                    ]
        in
        Svg.g [] [ circle, label ]


```
