package com.tylerflores.pocketclaude

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A test with nothing to say, on purpose.
 *
 * Its job is to prove the unit-test task actually runs in CI rather than being
 * silently skipped for having no tests to execute -- the same reason this
 * repository refuses a paths filter on a workflow. A green build that ran
 * nothing looks exactly like a green build that ran everything.
 */
class BuildSanityTest {
    @Test
    fun theTestTaskRuns() {
        assertEquals(4, 2 + 2)
    }
}
