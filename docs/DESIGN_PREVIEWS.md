# Easy appearance review

Both directions use the same Tasks, Home and Gym screens with the built-in sample workspace. Desktop keeps the dark surround, light work surface and sidebar. Mobile Home gives most of the screen to the day, with navigation and capture in the bottom corners. Gym keeps the red focus outline.

| View | Warm paper | Cool white |
| --- | --- | --- |
| Desktop Tasks · 1440 × 900 | [Warm paper Tasks](appearance-review/warm-paper-tasks.png) | [Cool white Tasks](appearance-review/cool-white-tasks.png) |
| Mobile Home · 390 × 844 | [Warm paper Home](appearance-review/warm-paper-home.png) | [Cool white Home](appearance-review/cool-white-home.png) |
| Mobile Gym · 390 × 844 | [Warm paper Gym](appearance-review/warm-paper-gym.png) | [Cool white Gym](appearance-review/cool-white-gym.png) |

**Warm paper** pairs a brown charcoal surround with an ivory work surface and olive controls. A larger Tasks heading, rounder work surface and taller list rows give the page more breathing room.

**Cool white** pairs a blue graphite surround with a cool white work surface and blue controls. Smaller corners, tighter spacing and wider list groups keep the page compact.

## Reproduce

The renderer builds a Linux release from revision `d8e9018` in a temporary directory. It applies the chosen appearance there, opens Easy on an isolated X11 display and captures the three routes. The sample dates come from the machine’s local clock. Capture before 09:30 local time to see all three upcoming events in the mobile Home image.

Use Python 3.12 or newer, the Flutter Linux build prerequisites, Flutter dependencies in the pub cache, Xvfb, xdotool, ImageMagick and Tesseract.

```sh
python3 tool/appearance_review/render.py warm-paper /tmp/easy-appearance
python3 tool/appearance_review/render.py cool-white /tmp/easy-appearance
```
