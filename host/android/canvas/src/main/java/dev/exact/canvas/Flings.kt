package dev.exact.canvas

import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent

/** LLP 1057.001 §8 on Android: `swipe` is the platform's fling, [GestureDetector.OnGestureListener.onFling], with
 * [android.view.ViewConfiguration]'s slop and velocities, over the view's whole touch, every pointer of it. It
 * fires at the lift; a touch the reader's scrolling or a hosted field kept is none. [swiped] hands exact2 the
 * direction and the most pointers the touch had down at once, and exact2 finds the node (`presenter/fling.rs`). */
internal class Flings(context: Context, swiped: (String, Int) -> Unit) {
    private val touch = FlingTouch(swiped)
    private val detector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float) =
            touch.fling(velocityX, velocityY)
    })

    /** Each event of the touch, after the reader and exact2 had it, and who [kept] it. */
    fun touch(e: MotionEvent, kept: Kept) {
        touch.event(e.actionMasked == MotionEvent.ACTION_DOWN, e.pointerCount, kept)
        detector.onTouchEvent(e)
    }
}

/** Who kept an event of a touch from exact2: the reader's scrolling, which has the rest of the touch once it takes
 * one, or a hosted field ([Fields]), which holds a touch until exact2 says whether the field is under it and
 * replays it to exact2 when not. */
internal enum class Kept { NONE, SCROLLING, FIELD }

/** What a touch's fling is, apart from the recognizer that finds it. */
internal class FlingTouch(private val swiped: (String, Int) -> Unit) {
    private var most = 0
    private var scrolled = false
    private var field = false

    fun event(down: Boolean, pointers: Int, kept: Kept) {
        if (down) { most = 0; scrolled = false }
        most = maxOf(most, pointers)
        scrolled = scrolled || kept == Kept.SCROLLING
        field = kept == Kept.FIELD
    }

    /** The recognizer's fling at ([velocityX], [velocityY]) px/s: whether it went to exact2, which it does unless the
     * reader's scrolling took the touch or a field has it at the lift. */
    fun fling(velocityX: Float, velocityY: Float): Boolean {
        if (scrolled || field) return false
        swiped(direction(velocityX, velocityY), most)
        return true
    }

    companion object {
        /** The velocity's larger axis and that axis's sign; y grows down. */
        fun direction(velocityX: Float, velocityY: Float): String =
            if (Math.abs(velocityX) > Math.abs(velocityY)) (if (velocityX > 0) "right" else "left")
            else if (velocityY > 0) "down" else "up"
    }
}
