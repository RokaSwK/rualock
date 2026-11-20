"""A Dynamic Island-style status extension that grows out of the camera notch.

The dot is green while you are recognised, amber with a countdown ring while
you are away, grey while paused or locked, red when the camera is unavailable.
Click to pause for an hour (or resume); right-click for more.
"""

from __future__ import annotations

import math
import threading
import time

import objc
from AppKit import (
    NSApp,
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSFontWeightSemibold,
    NSGraphicsContext,
    NSForegroundColorAttributeName,
    NSMenu,
    NSMenuItem,
    NSPanel,
    NSScreen,
    NSStatusBar,
    NSStatusWindowLevel,
    NSString,
    NSTimer,
    NSTrackingActiveAlways,
    NSTrackingArea,
    NSTrackingInVisibleRect,
    NSTrackingMouseEnteredAndExited,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)
from Foundation import NSMakeRect, NSObject
from PyObjCTools import AppHelper

import facelock

DOT = 5.0          # dot radius
RING = 8.5         # countdown ring radius
PAD = 9.0          # space around the dot on the floating pill
INNER = 1.0        # gap between the notch edge and the ring when attached to the notch
TAIL = 5.0         # space right of the dot when attached to the notch
TUCK = 2.0         # the shape's straight left edge sits this far under the notch, so no sliver shows
FILLET = 12.0      # fillet into the notch's rounded bottom corner (at least the corner's radius)
OVERLAP = TUCK + FILLET  # window starts this far left of the notch edge
EAR = 6.0          # concave flare where the shape meets the top bezel, like the notch's own
CORNER = 9.0       # bottom-right corner radius
TEXT_GAP = 7.0     # between the ring and the text
TEXT_PAD = 10.0    # right margin after the text
SPRING_K = 320.0   # spring stiffness for the hover animation
SPRING_DAMP = 24.0 # damping; below 2*sqrt(K) (~36) so it overshoots a little, then settles
PILL_H = 24.0      # fallback pill height on screens without a notch

GREEN = (0.19, 0.82, 0.35)
AMBER = (1.00, 0.62, 0.04)
RED = (1.00, 0.27, 0.23)
GREY = (0.56, 0.56, 0.60)

FONT = NSFont.systemFontOfSize_weight_(11.5, NSFontWeightSemibold)


def rgb(c: tuple[float, float, float], a: float = 1.0) -> NSColor:
    return NSColor.colorWithSRGBRed_green_blue_alpha_(c[0], c[1], c[2], a)


def geometry() -> tuple[float, float, float, bool]:
    """(left x, bottom y, height, attached-to-notch) for the window."""
    screens = list(NSScreen.screens())
    notched = [sc for sc in screens if sc.safeAreaInsets().top > 0]
    screen = notched[0] if notched else screens[0]
    f = screen.frame()
    top = f.origin.y + f.size.height
    if notched:
        h = screen.safeAreaInsets().top - 0.4525  # shorter than the notch, to match the camera housing
        return screen.auxiliaryTopRightArea().origin.x - OVERLAP, top - h, h, True
    bar = NSStatusBar.systemStatusBar().thickness()  # no notch: float a pill right of centre
    return f.origin.x + f.size.width / 2 + 60, top - bar + (bar - PILL_H) / 2, PILL_H, False


class IslandView(NSView):
    def initWithWatcher_(self, watcher):
        _, _, h, notch = geometry()
        self = objc.super(IslandView, self).initWithFrame_(NSMakeRect(0, 0, 60, h))
        if self is None:
            return None
        self.watcher = watcher
        self.hover = False
        self.notch = notch
        self.authenticating = False
        self.addTrackingArea_(
            NSTrackingArea.alloc().initWithRect_options_owner_userInfo_(
                NSMakeRect(0, 0, 0, 0),
                NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect,
                self,
                None,
            )
        )
        return self

    # ------------------------------------------------------------ state

    @objc.python_method
    def status(self) -> tuple[tuple[float, float, float], str, float | None]:
        """(dot colour, label, countdown fraction remaining or None)."""
        w = self.watcher
        s = w.state
        if s == "watching":
            return GREEN, "Watching", None
        if s == "absent":
            left = max(0.0, w.absent - w.absent_for)
            return AMBER, f"Locking in {math.ceil(left)}s", left / w.absent
        if s == "paused":
            window = facelock.pause_window()
            if window is None:
                return GREY, "Paused", None
            started, until = window
            left = max(0.0, until - time.time())
            label = f"Paused · {math.ceil(left / 60)}m" if left >= 60 else f"Paused · {math.ceil(left)}s"
            return GREY, label, min(1.0, left / max(1.0, until - started))
        if s == "locked":
            return GREY, "Locked", None
        if s == "nocam":
            return RED, "No camera", None
        return GREY, "Starting…", None

    @objc.python_method
    def expanded(self) -> bool:
        return self.hover

    @objc.python_method
    def lead(self) -> float:
        """x where the visible content starts."""
        return OVERLAP if self.notch else 2.0

    @objc.python_method
    def compact_width(self) -> float:
        if self.notch:  # the notch is already black, so the dot sits right against it
            return OVERLAP + INNER + 2 * RING + TAIL + EAR
        return self.lead() + 2 * (PAD + RING) - 2

    @objc.python_method
    def text_x(self) -> float:
        left = OVERLAP + INNER if self.notch else self.lead() + PAD - 1
        return left + 2 * RING + TEXT_GAP

    @objc.python_method
    def expanded_width(self) -> float:
        _, label, _ = self.status()
        text_w = NSString.stringWithString_(label).sizeWithAttributes_({NSFontAttributeName: FONT}).width
        right = TEXT_PAD + (EAR if self.notch else 0)
        return self.text_x() + text_w + right

    @objc.python_method
    def target_width(self) -> float:
        return self.expanded_width() if self.expanded() else self.compact_width()

    @objc.python_method
    def reveal(self) -> float:
        """0 when compact, 1 when fully open; drives the text fade and slide."""
        compact, full = self.compact_width(), self.expanded_width()
        t = (self.bounds().size.width - compact) / max(1.0, full - compact)
        t = min(1.0, max(0.0, t))
        t = min(1.0, max(0.0, (t - 0.35) / 0.65))  # text starts once the shape is about a third open
        return t * t * (3 - 2 * t)  # smoothstep

    @objc.python_method
    def shape(self):
        b = self.bounds()
        w, h = b.size.width, b.size.height
        if not self.notch:
            return NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(b, h / 2, h / 2)
        # Square on the notch side, flared into the top bezel and rounded at the bottom on the right,
        # so it reads as the notch growing sideways.
        p = NSBezierPath.bezierPath()
        # Starts at the notch edge (x = OVERLAP). Bottom-left, a fillet reaches into the notch to fill
        # the wedge its rounded corner leaves; anything else under the notch is hidden by the hardware.
        p.moveToPoint_((FILLET, h))
        p.lineToPoint_((w, h))
        p.curveToPoint_controlPoint1_controlPoint2_((w - EAR, h - EAR), (w - EAR * 0.45, h), (w - EAR, h - EAR * 0.45))
        p.lineToPoint_((w - EAR, CORNER))
        p.curveToPoint_controlPoint1_controlPoint2_((w - EAR - CORNER, 0), (w - EAR, CORNER * 0.45), (w - EAR - CORNER * 0.45, 0))
        p.lineToPoint_((0, 0))
        p.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_((0, FILLET), FILLET, 270, 360, False)
        p.closePath()
        return p

    # ------------------------------------------------------------ drawing

    def drawRect_(self, rect):
        b = self.bounds()
        NSColor.blackColor().setFill()
        self.shape().fill()

        colour, label, frac = self.status()
        left = OVERLAP + INNER if self.notch else self.lead() + PAD - 1
        cx, cy = left + RING, b.size.height / 2

        if frac is not None:  # countdown ring
            track = NSBezierPath.bezierPath()
            track.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_((cx, cy), RING, 0, 360)
            track.setLineWidth_(2)
            rgb(colour, 0.25).setStroke()
            track.stroke()
            arc = NSBezierPath.bezierPath()
            arc.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_(
                (cx, cy), RING, 90, 90 - 360 * frac, True
            )
            arc.setLineWidth_(2)
            rgb(colour).setStroke()
            arc.stroke()
        elif colour == GREEN:  # soft breathing glow
            glow = 0.18 + 0.12 * math.sin(time.monotonic() * 2.2)
            rgb(colour, glow).setFill()
            NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(cx - RING, cy - RING, 2 * RING, 2 * RING)).fill()

        rgb(colour).setFill()
        NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(cx - DOT, cy - DOT, 2 * DOT, 2 * DOT)).fill()

        r = self.reveal()
        if r > 0.01:
            NSGraphicsContext.currentContext().saveGraphicsState()
            self.shape().addClip()  # text never spills past the shape while it grows or shrinks
            attrs = {
                NSFontAttributeName: FONT,
                NSForegroundColorAttributeName: NSColor.colorWithWhite_alpha_(1.0, r),
            }
            s = NSString.stringWithString_(label)
            th = s.sizeWithAttributes_(attrs).height
            s.drawAtPoint_withAttributes_((self.text_x() - 6 * (1 - r), (b.size.height - th) / 2), attrs)
            NSGraphicsContext.currentContext().restoreGraphicsState()

    # ------------------------------------------------------------ mouse

    def acceptsFirstMouse_(self, event):
        return True

    def mouseEntered_(self, event):
        self.hover = True

    def mouseExited_(self, event):
        self.hover = False

    def mouseDown_(self, event):
        if facelock.paused():
            self.resume_(None)
        else:
            self.pause15_(None)

    def rightMouseDown_(self, event):
        menu = NSMenu.alloc().init()
        for title, sel in (
            ("Pause 15 minutes", "pause15:"),
            ("Pause 1 hour", "pause60:"),
            ("Resume", "resume:"),
            (None, None),
            ("Lock now", "lockNow:"),
            ("Quit localsec", "quit:"),
        ):
            if title is None:
                menu.addItem_(NSMenuItem.separatorItem())
                continue
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, sel, "")
            item.setTarget_(self)
            menu.addItem_(item)
        NSMenu.popUpContextMenu_withEvent_forView_(menu, event, self)

    @objc.python_method
    def _pause(self, minutes: float) -> None:
        """Pausing turns protection off, so it needs Touch ID (or the Mac password)."""
        if self.authenticating:
            return
        self.authenticating = True

        def done(ok: bool) -> None:
            def apply() -> None:
                self.authenticating = False
                if ok:
                    facelock.set_pause(minutes)
                    facelock.log(f"paused for {minutes:g} min")

            AppHelper.callAfter(apply)

        facelock.authenticate_async(facelock.pause_reason(minutes), done)

    def pause15_(self, sender):
        self._pause(15)

    def pause60_(self, sender):
        self._pause(60)

    def resume_(self, sender):
        facelock.PAUSE_FILE.unlink(missing_ok=True)

    def lockNow_(self, sender):
        facelock.lock_screen()

    def quit_(self, sender):
        self.watcher.stop.set()
        NSApp.terminate_(None)


class Controller(NSObject):
    def initWithWindow_view_(self, window, view):
        self = objc.super(Controller, self).init()
        if self is None:
            return None
        self.window, self.view = window, view
        self.width = view.compact_width()
        self.velocity = 0.0
        self.last = time.monotonic()
        return self

    def tick_(self, timer):
        now = time.monotonic()
        dt = min(1 / 30, now - self.last)
        self.last = now

        x, y, h, notch = geometry()  # follows display changes
        self.view.notch = notch

        # Spring towards the target width: a little overshoot, then settles, like the Dynamic Island.
        target = self.view.target_width()
        force = SPRING_K * (target - self.width) - SPRING_DAMP * self.velocity
        self.velocity += force * dt
        self.width += self.velocity * dt
        if abs(target - self.width) < 0.05 and abs(self.velocity) < 0.05:
            self.width, self.velocity = target, 0.0

        f = self.window.frame()
        if (
            abs(f.size.width - self.width) > 0.01
            or abs(f.origin.x - x) > 0.01
            or abs(f.origin.y - y) > 0.01
            or abs(f.size.height - h) > 0.01
        ):
            self.window.setFrame_display_(NSMakeRect(x, y, self.width, h), True)
        self.view.setNeedsDisplay_(True)


def main(watcher) -> None:
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)  # no Dock icon

    x, y, h, _ = geometry()
    panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(x, y, 60, h),
        NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
        NSBackingStoreBuffered,
        False,
    )
    panel.setOpaque_(False)
    panel.setBackgroundColor_(NSColor.clearColor())
    panel.setHasShadow_(False)
    panel.setLevel_(NSStatusWindowLevel + 1)  # above the menu bar
    panel.setCollectionBehavior_(
        NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorStationary
        | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorIgnoresCycle
    )
    panel.setHidesOnDeactivate_(False)
    panel.setMovable_(False)

    view = IslandView.alloc().initWithWatcher_(watcher)
    view.setAutoresizingMask_(18)  # width + height sizable
    panel.setContentView_(view)
    panel.orderFrontRegardless()

    controller = Controller.alloc().initWithWindow_view_(panel, view)
    NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1 / 60, controller, "tick:", None, True)

    def run_watcher() -> None:
        try:
            watcher.run()
        finally:
            AppHelper.callAfter(NSApp.terminate_, None)

    threading.Thread(target=run_watcher, daemon=True).start()
    AppHelper.runEventLoop(installInterrupt=True)
