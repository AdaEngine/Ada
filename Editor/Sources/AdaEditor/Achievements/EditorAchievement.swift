import Foundation

enum EditorAchievementID: String, Codable, CaseIterable, Sendable {
    case firstProject, firstScene, firstRun, firstImport, firstSprite, firstLight, camera
    case hierarchy, components, physics, script, scriptField, animation, choreography
    case firstUI, layout, binding, sceneInstance, population, activeDays
    case answer42, newton, inception, redo, flip, helloAda
}

struct EditorAchievement: Identifiable, Sendable {
    let id: EditorAchievementID
    let englishTitle: String
    let russianTitle: String
    let englishDetail: String
    let russianDetail: String
    let goal: Int
    let points: Int
    let secret: Bool

    var title: String { Self.isRussian ? russianTitle : englishTitle }
    var detail: String { Self.isRussian ? russianDetail : englishDetail }
    var gameCenterID: String { "org.adaengine.editor.achievement.\(id.rawValue)" }
    static var isRussian: Bool { Locale.preferredLanguages.first?.hasPrefix("ru") == true }

    init(
        _ id: EditorAchievementID,
        _ title: String,
        _ ru: String,
        _ detail: String,
        _ ruDetail: String,
        goal: Int = 1,
        points: Int = 10,
        secret: Bool = false
    ) {
        self.id = id
        englishTitle = title
        russianTitle = ru
        englishDetail = detail
        russianDetail = ruDetail
        self.goal = goal
        self.points = points
        self.secret = secret
    }

    static let catalog: [Self] = [
        .init(.firstProject, "A Beginning", "Начало положено", "Create your first project.", "Создайте первый проект."),
        .init(.firstScene, "First World", "Первый мир", "Edit and save a scene.", "Измените и сохраните сцену."),
        .init(.firstRun, "It's Alive!", "Оно живое!", "Successfully load a scene in Play Mode.", "Успешно запустите сцену в редакторе."),
        .init(.firstImport, "Your Materials", "Свои материалы", "Import an asset into a project.", "Импортируйте ресурс в проект."),
        .init(.firstSprite, "First Pixel", "Первый пиксель", "Assign a local texture to a sprite and save.", "Назначьте спрайту свою текстуру и сохраните сцену."),
        .init(.firstLight, "Let There Be Light", "Да будет свет", "Add a 2D light and save the scene.", "Добавьте источник света 2D и сохраните сцену."),
        .init(.camera, "In the Frame", "Всё в кадре", "Change camera settings and save.", "Измените настройки камеры и сохраните сцену."),
        .init(.hierarchy, "Family Tree", "Семейное дерево", "Save a parent with three children.", "Сохраните сущность с тремя дочерними.", points: 20),
        .init(.components, "Made of Parts", "Из деталей", "Save an entity with three extra components.", "Сохраните сущность с тремя компонентами сверх стандартных.", points: 20),
        .init(.physics, "Laws of Nature", "Законы природы", "Run a scene with a dynamic body and collision shape.", "Запустите сцену с динамическим телом и коллайдером.", points: 20),
        .init(.script, "First Spell", "Первое заклинание", "Run a scene with an AdaScript component.", "Запустите сцену с AdaScript-компонентом.", points: 20),
        .init(.scriptField, "Control Knobs", "Ручки управления", "Edit an AdaScript field in the Inspector and save.", "Измените поле AdaScript в Inspector и сохраните сцену.", points: 20),
        .init(.animation, "Action!", "Мотор!", "Preview an animation with two different keyframes.", "Включите предпросмотр анимации с двумя различающимися ключевыми кадрами.", points: 20),
        .init(.choreography, "Choreographer", "Хореограф", "Save a clip animating three properties.", "Сохраните клип с анимацией трёх свойств.", points: 30),
        .init(.firstUI, "First Screen", "Первый экран", "Add an element to a UI document and save.", "Добавьте элемент в UI Designer и сохраните документ."),
        .init(
            .layout,
            "Everything in Place",
            "Всё по полочкам",
            "Save a UI with nested containers and five content elements.",
            "Сохраните UI с вложенными контейнерами и пятью элементами.",
            points: 30
        ),
        .init(.binding, "Connected", "Связь установлена", "Run a scene with a UI bound to an AdaScript field.", "Запустите сцену с UI, привязанным к полю AdaScript.", points: 30),
        .init(.sceneInstance, "World Within a World", "Мир внутри мира", "Save a scene containing another scene.", "Добавьте экземпляр другой сцены и сохраните.", points: 20),
        .init(
            .population,
            "Growing World",
            "Набирая масштаб",
            "Save a scene with 50 entities, excluding its root.",
            "Сохраните сцену с 50 сущностями, не считая корня.",
            goal: 50,
            points: 40
        ),
        .init(
            .activeDays,
            "Returning Author",
            "Возвращение автора",
            "Edit and save on seven different days. No streak required.",
            "Редактируйте и сохраняйте в 7 разных дней. Подряд не требуется.",
            goal: 7,
            points: 40
        ),
        .init(.answer42, "The Answer", "Ответ на главный вопрос", "Save exactly 42 entities, excluding the root.", "Сохраните ровно 42 сущности, не считая корня.", points: 20, secret: true),
        .init(
            .newton,
            "Newton Approves",
            "Ньютон одобряет",
            "Run a dynamic body named Apple with a collision shape.",
            "Запустите динамическое тело Apple с коллайдером.",
            points: 20,
            secret: true
        ),
        .init(.inception, "Inception", "Начало", "Save a chain of three nested scenes: A → B → C.", "Сохраните три уровня вложенных сцен: A → B → C.", points: 30, secret: true),
        .init(.redo, "As Intended", "Я так и задумал", "Undo an edit, redo it, then save the document.", "Отмените изменение, верните через Redo и сохраните.", points: 10, secret: true),
        .init(.flip, "Inside Out", "Наизнанку", "Save a sprite with both Flip X and Flip Y enabled.", "Сохраните спрайт с включёнными Flip X и Flip Y.", points: 10, secret: true),
        .init(.helloAda, "Hello, Ada", "Привет, Ада", "Save a UI Text element saying Hello, Ada!", "Сохраните текстовый элемент UI со строкой Hello, Ada!", points: 10, secret: true),
    ]
}

struct EditorAchievementProgress: Codable, Equatable, Sendable {
    var value = 0
    var earnedAt: Date?
}

struct EditorAchievementProfile: Codable, Sendable {
    var progress: [EditorAchievementID: EditorAchievementProgress] = [:]
    var activeDays: Set<String> = []
}

struct EditorAchievementSnapshot: Codable, Sendable {
    var version = 1
    var activeProfileID = "local"
    var profiles: [String: EditorAchievementProfile] = [:]
    var guestOwner: String?
    var notificationsEnabled = true
    var gameCenterEnabled = false
}

/// Platform adapters exchange stable editor IDs. A future Steam adapter doesn't change achievement rules.
@MainActor
protocol EditorAchievementProvider: AnyObject {
    var playerID: String? { get }
    var onPlayerChanged: ((String?) -> Void)? { get set }
    func authenticate()
    func load() async throws -> [EditorAchievementID: Double]
    func report(_ progress: [EditorAchievementID: Double]) async throws
    func showAchievements()
}
