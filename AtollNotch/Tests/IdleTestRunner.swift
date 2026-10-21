/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

import Foundation

// Entry point of the pure idle-engine test binary (AtollNotch/Tests/run_idle.sh builds it from Core/IdleAnimation*.swift).

@main
struct IdleCoreTestMain {
    static func main() {
        runLottieValidatorTests()
        runSpriteValidatorTests()
        runImportTests()
        runPlaybackTests()
        runMigrationTests()
        runMotionTests()
        print("")
        print("idle core tests: \(IdleT.passes) passed, \(IdleT.failures) failed")
        exit(IdleT.failures == 0 ? 0 : 1)
    }
}
