import Foundation
import XCTest
@testable import PostureLab

/// The one property the policy writes, recorded so a test can see both the current answer and how
/// often it was written.
@MainActor
private final class FakeApplication: IdleTimerControlling {
  var isIdleTimerDisabled = false {
    didSet { writes.append(isIdleTimerDisabled) }
  }
  /// Every value written, in order: the evidence that an unchanged answer writes nothing.
  private(set) var writes: [Bool] = []
}

/// One run's screen state, driven the way `SessionController` drives it: the real `PomodoroEngine`
/// for the timer, the controller's own `focusOpen` rule for "a focus was started and not closed
/// yet", and an `IdleTimerController` writing into a fake application.
@MainActor
private final class ScreenRig {
  private final class Clock {
    var now: TimeInterval = 0
  }

  let application = FakeApplication()
  let idleTimer: IdleTimerController
  var engine: PomodoroEngine
  var keepScreenAwake = true
  var sceneActive = true
  private(set) var focusOpen = false

  private let clock = Clock()
  private var recordID: UUID

  /// A one-minute focus and break keep the sample runs short; the state machine is the same one the
  /// app runs on.
  init() {
    var settings = PomodoroSettings()
    settings.focusMinutes = 1
    settings.shortBreakMinutes = 1
    settings.longBreakMinutes = 1
    idleTimer = IdleTimerController(application: application)
    engine = PomodoroEngine(settings: settings, now: { [clock] in clock.now })
    recordID = engine.record.id
    // The first evaluation, as `RootView`'s `scenePhase` report does at launch: the parked focus
    // writes "let the screen go" once.
    sync()
  }

  var screenHeld: Bool { application.isIdleTimerDisabled }

  /// Evaluates and applies the policy from the current state, exactly as the controller does on every
  /// state change.
  func sync() {
    idleTimer.update(IdleTimerPolicy(keepScreenAwake: keepScreenAwake,
                                     pomodoro: engine,
                                     focusOpen: focusOpen,
                                     isSceneActive: sceneActive))
  }

  func command(_ command: PomodoroCommand) {
    settle(engine.command(command))
  }

  /// Runs of samples at the 10 Hz camera tick, from `start` seconds; `present` false is the same tick
  /// with no face in frame.
  @discardableResult
  func feed(_ count: Int, present: Bool = true, from start: TimeInterval = 0) -> [PomodoroEvent] {
    var events: [PomodoroEvent] = []
    for index in 1...count {
      let t = start + Double(index) / 10
      clock.now = t
      let sample = PostureSample(t: t,
                                 distanceCM: present ? 40 : nil,
                                 pitchDeg: present ? 15 : nil)
      events += engine.ingest(sample)
    }
    settle(events)
    return events
  }

  /// The end of a scripted run (`SessionController.finishPomodoroRun`).
  func finish() {
    clock.now += 1
    settle(engine.finish())
  }

  /// `SessionController`'s own bookkeeping: a new record id is an opened focus, and a completion, an
  /// abandonment or an interruption closes it.
  private func settle(_ events: [PomodoroEvent]) {
    if engine.record.id != recordID {
      recordID = engine.record.id
      focusOpen = true
    }
    for event in events {
      switch event {
      case .completed, .abandoned, .interrupted: focusOpen = false
      default: break
      }
    }
    sync()
  }
}

final class IdleTimerTests: XCTestCase {
  // MARK: - The pure policy

  func testThePolicyHoldsTheScreenOnlyForACountingFocusOnAnActiveScene() {
    for keep in [true, false] {
      for counting in [true, false] {
        for active in [true, false] {
          let policy = IdleTimerPolicy(keepScreenAwake: keep,
                                       isFocusCounting: counting,
                                       isSceneActive: active)
          XCTAssertEqual(policy.disablesIdleTimer, keep && counting && active,
                         "keep=\(keep) counting=\(counting) active=\(active)")
        }
      }
    }
  }

  @MainActor
  func testTheControllerWaitsForAnApplicationInsteadOfWritingThroughNil() {
    // What the launch path sees: the app object does not exist yet. 0.6.3's first build cached
    // `UIApplication.shared` here and crashed writing through the nil on every launch.
    var application: FakeApplication?
    let idleTimer = IdleTimerController(application: { application })
    let counting = IdleTimerPolicy(keepScreenAwake: true, isFocusCounting: true, isSceneActive: true)

    XCTAssertFalse(idleTimer.update(counting), "wrote before there was an application")
    XCTAssertEqual(idleTimer.policy, counting)
    XCTAssertFalse(idleTimer.isDisabled)

    // The first evaluation after the application exists writes the answer it finds.
    application = FakeApplication()
    XCTAssertTrue(idleTimer.update(counting))
    XCTAssertEqual(application?.writes, [true])
    XCTAssertTrue(idleTimer.isDisabled)
  }

  @MainActor
  func testTheControllerWritesOnlyWhenTheAnswerChanges() {
    let application = FakeApplication()
    let idleTimer = IdleTimerController(application: application)
    let counting = IdleTimerPolicy(keepScreenAwake: true, isFocusCounting: true, isSceneActive: true)
    let parked = IdleTimerPolicy(keepScreenAwake: true, isFocusCounting: false, isSceneActive: true)

    XCTAssertTrue(idleTimer.update(counting))
    XCTAssertEqual(application.writes, [true])
    XCTAssertEqual(idleTimer.policy, counting)
    XCTAssertTrue(idleTimer.isDisabled)

    // The same answer, over and over: the policy is read on every sample, so it must not write.
    XCTAssertFalse(idleTimer.update(counting))
    XCTAssertFalse(idleTimer.update(counting))
    XCTAssertEqual(application.writes, [true])

    XCTAssertTrue(idleTimer.update(parked))
    XCTAssertEqual(application.writes, [true, false])
    XCTAssertFalse(idleTimer.isDisabled)
  }

  // MARK: - Every transition, through the timer the app runs

  @MainActor
  func testAParkedFocusDoesNotHoldTheScreen() {
    let rig = ScreenRig()
    rig.sync()
    XCTAssertFalse(rig.screenHeld)
    XCTAssertEqual(rig.application.writes, [false])
  }

  @MainActor
  func testStartingAFocusHoldsTheScreen() {
    let rig = ScreenRig()
    rig.command(.start)
    XCTAssertTrue(rig.screenHeld)
    XCTAssertEqual(rig.application.writes, [false, true])
  }

  @MainActor
  func testPausingReleasesTheScreenAndResumingHoldsItAgain() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.feed(10)
    XCTAssertTrue(rig.screenHeld)

    rig.command(.pause)
    XCTAssertFalse(rig.screenHeld)

    rig.command(.resume)
    XCTAssertTrue(rig.screenHeld)
  }

  @MainActor
  func testAbandoningReleasesTheScreen() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.feed(50)
    XCTAssertTrue(rig.screenHeld)

    rig.command(.abandon)
    XCTAssertFalse(rig.screenHeld)
  }

  @MainActor
  func testABreakReleasesTheScreenAndTheNextFocusHoldsItOnceStarted() {
    let rig = ScreenRig()
    rig.command(.start)
    let events = rig.feed(600)
    XCTAssertTrue(events.contains { if case .phaseChanged(to: .shortBreak, index: 1) = $0 { return true } else { return false } })
    XCTAssertEqual(rig.engine.phase, .shortBreak)
    XCTAssertFalse(rig.screenHeld)

    // The break ends into a focus waiting for 开始: still no screen to hold.
    rig.feed(600, from: 60)
    XCTAssertEqual(rig.engine.phase, .focus)
    XCTAssertFalse(rig.engine.isRunning)
    XCTAssertFalse(rig.screenHeld)

    rig.command(.start)
    XCTAssertTrue(rig.screenHeld)
  }

  @MainActor
  func testFinishingTheSessionReleasesTheScreen() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.feed(30)
    XCTAssertTrue(rig.screenHeld)

    rig.finish()
    XCTAssertFalse(rig.screenHeld)
  }

  @MainActor
  func testBackgroundingReleasesTheScreenAndReturningHoldsItWhileTheFocusCounts() {
    let rig = ScreenRig()
    rig.command(.start)
    XCTAssertTrue(rig.screenHeld)

    rig.sceneActive = false
    rig.sync()
    XCTAssertFalse(rig.screenHeld)

    rig.sceneActive = true
    rig.sync()
    XCTAssertTrue(rig.screenHeld)
  }

  @MainActor
  func testReturningToTheForegroundWhilePausedLeavesTheScreenAlone() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.command(.pause)

    rig.sceneActive = false
    rig.sync()
    rig.sceneActive = true
    rig.sync()
    XCTAssertFalse(rig.screenHeld)
  }

  @MainActor
  func testBackgroundingAndReturningAfterTheRunEndedLeavesTheScreenAlone() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.finish()
    let writes = rig.application.writes.count

    rig.sceneActive = false
    rig.sync()
    rig.sceneActive = true
    rig.sync()
    XCTAssertFalse(rig.screenHeld)
    // Nothing left to write: the answer was already "let the screen go".
    XCTAssertEqual(rig.application.writes.count, writes)
  }

  @MainActor
  func testAnAbsenceSuspensionReleasesTheScreenAndTheChildsReturnHoldsItAgain() {
    let rig = ScreenRig()
    rig.command(.start)
    rig.feed(10)
    XCTAssertTrue(rig.screenHeld)

    rig.feed(10, present: false, from: 1)
    XCTAssertTrue(rig.engine.isPausedByAbsence)
    XCTAssertFalse(rig.screenHeld)

    rig.feed(10, present: true, from: 2)
    XCTAssertFalse(rig.engine.isPausedByAbsence)
    XCTAssertTrue(rig.screenHeld)
  }

  @MainActor
  func testTheKeepScreenAwakeSwitchOffKeepsTheScreenOffMidFocus() {
    let rig = ScreenRig()
    rig.keepScreenAwake = false
    rig.command(.start)
    rig.feed(10)
    XCTAssertTrue(rig.engine.isRunning)
    XCTAssertFalse(rig.screenHeld)

    // Flipped back on from the settings page while the focus counts.
    rig.keepScreenAwake = true
    rig.sync()
    XCTAssertTrue(rig.screenHeld)
  }
}
