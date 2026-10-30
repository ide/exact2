package dev.exact.canvas

import org.junit.Assert.*
import org.junit.Test

/** LLP 1057.001 §8 on Android, the reader's half: a fling at the lift goes to exact2 with its direction and the
 * most pointers its touch had down, unless the reader's scrolling took the touch or a hosted field has it. */
class FlingTouchTest {
    private val sent = mutableListOf<String>()
    private val touch = FlingTouch { direction, pointers -> sent.add("$direction $pointers") }

    @Test fun aFlingGoesItsVelocitysLargerAxisAndSign() {
        assertEquals("right", FlingTouch.direction(900f, -300f))
        assertEquals("left", FlingTouch.direction(-900f, 300f))
        assertEquals("down", FlingTouch.direction(300f, 900f))
        assertEquals("up", FlingTouch.direction(-300f, -900f))
        assertEquals("a tie is vertical", "down", FlingTouch.direction(500f, 500f))
    }

    @Test fun aTouchTheReaderKeptFlingsNothing() {
        touch.event(down = true, pointers = 1, kept = Kept.NONE)
        touch.event(down = false, pointers = 1, kept = Kept.SCROLLING)
        touch.event(down = false, pointers = 1, kept = Kept.NONE)
        assertFalse(touch.fling(-900f, 0f))
        // The next touch starts clean
        touch.event(down = true, pointers = 1, kept = Kept.NONE)
        assertTrue(touch.fling(-900f, 0f))
        assertEquals(listOf("left 1"), sent)
    }

    /** A field holds a touch until exact2 answers, and replays it to exact2 when the field is not under it. */
    @Test fun aFieldKeepsTheFlingOnlyOfATouchItHasAtTheLift() {
        touch.event(down = true, pointers = 1, kept = Kept.FIELD)
        touch.event(down = false, pointers = 1, kept = Kept.FIELD)
        assertFalse("the field's", touch.fling(0f, 900f))
        touch.event(down = true, pointers = 1, kept = Kept.FIELD)
        touch.event(down = false, pointers = 1, kept = Kept.NONE)
        assertTrue("given back to exact2", touch.fling(0f, 900f))
        assertEquals(listOf("down 1"), sent)
    }

    @Test fun theCountIsTheMostPointersDownAtOnceAHandOffIncluded() {
        touch.event(down = true, pointers = 1, kept = Kept.NONE)
        touch.event(down = false, pointers = 2, kept = Kept.NONE)
        // The first finger lifts and the second flings on: one pointer at the lift
        touch.event(down = false, pointers = 1, kept = Kept.NONE)
        assertTrue(touch.fling(0f, -1200f))
        touch.event(down = true, pointers = 1, kept = Kept.NONE)
        assertTrue(touch.fling(0f, 1200f))
        assertEquals(listOf("up 2", "down 1"), sent)
    }
}
