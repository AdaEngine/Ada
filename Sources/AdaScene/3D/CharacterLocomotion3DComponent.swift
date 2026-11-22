import AdaECS

/// Drives a root character's skinned model from the resolved motion of its 3D controller.
@Component
public struct CharacterLocomotion3DComponent: Codable, Sendable {
    public enum FacingMode: String, Codable, Sendable {
        case turnToMovement
        case keepFacing
    }

    /// The model's authored forward direction when its owner's rotation is identity.
    public enum ForwardAxis: String, Codable, Sendable {
        case positiveZ, positiveX, negativeZ, negativeX
    }

    public enum Phase: String, Sendable {
        case idle, walk, run, jump, fall, land
    }

    public enum Diagnostic: Equatable, Sendable {
        case requiresRootCharacter
        case modelUnavailable
        case playbackConflict
        case invalidTuning
        case missingClip(String)
        case ambiguousClip(String)
    }

    /// Names of the model's idle, forward gait, and air clips.
    public struct Clips: Codable, Equatable, Sendable {
        public var idle: String
        public var walk: String
        public var run: String
        public var jump: String
        public var fall: String
        public var land: String

        public init(
            idle: String = "Idle",
            walk: String = "Walk",
            run: String = "Run",
            jump: String = "Jump",
            fall: String = "Fall",
            land: String = "Land"
        ) {
            self.idle = idle
            self.walk = walk
            self.run = run
            self.jump = jump
            self.fall = fall
            self.land = land
        }

        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            idle = try values.decodeIfPresent(String.self, forKey: .idle) ?? idle
            walk = try values.decodeIfPresent(String.self, forKey: .walk) ?? walk
            run = try values.decodeIfPresent(String.self, forKey: .run) ?? run
            jump = try values.decodeIfPresent(String.self, forKey: .jump) ?? jump
            fall = try values.decodeIfPresent(String.self, forKey: .fall) ?? fall
            land = try values.decodeIfPresent(String.self, forKey: .land) ?? land
        }
    }

    /// Optional clips for a non-forward direction. Each absent clip uses the forward gait.
    public struct DirectionalGaits: Codable, Equatable, Sendable {
        public var walk: String?
        public var run: String?

        public init(walk: String? = nil, run: String? = nil) {
            self.walk = walk
            self.run = run
        }
    }

    public struct Configuration: Codable, Equatable, Sendable {
        public var clips = Clips()
        public var left = DirectionalGaits()
        public var right = DirectionalGaits()
        public var back = DirectionalGaits()
        public var facingMode: FacingMode = .turnToMovement
        public var forwardAxis: ForwardAxis = .positiveZ
        /// Ground speeds in meters per second at which each clip plays at its authored rate.
        public var walkReferenceSpeed: Float = 1.1
        public var runReferenceSpeed: Float = 2.2
        /// Fade durations in seconds.
        public var gaitTransitionDuration: Double = 0.22
        public var airTransitionDuration: Double = 0.08
        /// Number of simulated seconds spent in Land before resuming a grounded gait.
        public var landingDuration: Double = 0.25

        public init() {}

        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            clips = try values.decodeIfPresent(Clips.self, forKey: .clips) ?? clips
            left = try values.decodeIfPresent(DirectionalGaits.self, forKey: .left) ?? left
            right = try values.decodeIfPresent(DirectionalGaits.self, forKey: .right) ?? right
            back = try values.decodeIfPresent(DirectionalGaits.self, forKey: .back) ?? back
            facingMode = try values.decodeIfPresent(FacingMode.self, forKey: .facingMode) ?? facingMode
            forwardAxis = try values.decodeIfPresent(ForwardAxis.self, forKey: .forwardAxis) ?? forwardAxis
            walkReferenceSpeed = try values.decodeIfPresent(Float.self, forKey: .walkReferenceSpeed) ?? walkReferenceSpeed
            runReferenceSpeed = try values.decodeIfPresent(Float.self, forKey: .runReferenceSpeed) ?? runReferenceSpeed
            gaitTransitionDuration = try values.decodeIfPresent(Double.self, forKey: .gaitTransitionDuration) ?? gaitTransitionDuration
            airTransitionDuration = try values.decodeIfPresent(Double.self, forKey: .airTransitionDuration) ?? airTransitionDuration
            landingDuration = try values.decodeIfPresent(Double.self, forKey: .landingDuration) ?? landingDuration
        }
    }

    public var configuration: Configuration
    public var isEnabled: Bool
    public var activeState: Phase? { runtime.motion.request?.state }
    public var diagnostic: Diagnostic? { runtime.diagnostic }

    var runtime = CharacterLocomotion3DRuntime()

    private enum CodingKeys: String, CodingKey {
        case configuration, isEnabled
    }

    public init(configuration: Configuration = .init(), isEnabled: Bool = true) {
        self.configuration = configuration
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configuration: try values.decodeIfPresent(Configuration.self, forKey: .configuration) ?? .init(),
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
    }
}
