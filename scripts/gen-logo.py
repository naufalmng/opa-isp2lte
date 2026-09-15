#!/usr/bin/env python3
"""Generate OPA-ISP2LTE logo: figlet ANSI Shadow + ANSI truecolor gradient."""
import subprocess, sys

def ansi_shadow(text, width=120):
    return subprocess.run(
        ["python3", "-m", "pyfiglet", text, "-f", "ansi_shadow", "-w", str(width)],
        capture_output=True, text=True
    ).stdout.rstrip("\n")

def gradient_rgb(start, end, steps):
    """Interpolate between two RGB tuples."""
    return tuple(
        int(start[i] + (end[i] - start[i]) * (t / max(steps - 1, 1)))
        for t in range(steps)
        for i in range(3)
    )

def colorize(art, start=(0, 255, 255), end=(255, 0, 255)):
    """Color each non-space glyph with a horizontal truecolor gradient."""
    lines = art.split("\n")
    out = []
    for line in lines:
        colored = []
        # gradient across the width of this line
        w = max(len(line), 1)
        for x, ch in enumerate(line):
            if ch == " ":
                colored.append(" ")
                continue
            r, g, b = gradient_rgb(start, end, w)[x * 3 : x * 3 + 3]
            colored.append(f"\033[38;2;{r};{g};{b}m{ch}\033[0m")
        out.append("".join(colored))
    return "\n".join(out)

if __name__ == "__main__":
    text = sys.argv[1] if len(sys.argv) > 1 else "OPA-ISP2LTE"
    art = ansi_shadow(text)
    print(colorize(art))
