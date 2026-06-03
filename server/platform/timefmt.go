package platform

import (
	"fmt"
	"time"
)

// HumanizeSince renders elapsed time since t as a coarse relative string:
// "just now", "Nm ago", "Nh ago", "Nd ago". Used by /admin and /chat/recent.
func HumanizeSince(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}
