extern var Tasks;
extern var Time;
extern var __adaAssets;
extern var __adaTaskFromOperation;
@resource(id: "aot.async.stats", autoInsert: true)
struct NativeAsyncStats { @export var result = 0; @export var done = false; }
@system(id: "native.async")
class NativeAsyncSystem {
    @resource(NativeAsyncStats) var stats;
    var started = false;
    var sum = 0;
    var answer = Tasks.promise();
    async func child(value) { await Tasks.nextFrame(); return value + 2; }
    async func advance() {
        for (var value in [1,2,3]) { sum = sum + await self.child(value); }
        await Time.sleep(0.2);
        var extra = await answer;
        stats.result = sum + extra;
        stats.done = true;
    }
    func update(context) {
        if (!started) { started = true; Tasks.start(self.advance()); }
        if (context.deltaTime > 0.0) { answer.complete(30); }
    }
}
@scriptable(id: "aot.async.controller", version: 1)
class NativeAsyncController {
    @export var frames = 0;
    func ready(context) { Tasks.start(self.advance()); }
    async func advance() {
        while (frames < 10) { await Tasks.nextFrame(); frames = frames + 1; }
    }
}
class NativeAsyncProbe {
    var counter = 0;
    var order = 0;
    var retained = null;
    func retain(values) { retained = values; }
    func retainedComplete() { return retained[0].isComplete(); }
    func clearRetained() { retained = null; }
    func begin() { Tasks.start(self.ordered()); order = 7; }
    async func ordered() { counter = order; await Tasks.nextFrame(); counter = counter + 1; }
    async func stale(context) { counter = counter + 1; await Tasks.nextFrame(); return context.deltaTime; }
    async func nested() { for (var i in [1,2,3]) { counter = counter + await self.child(i); } return counter; }
    async func child(value) { await Tasks.nextFrame(); return value + 2; }
    async func longLoop() { var count = 0; while (count < 5000) { await Tasks.nextFrame(); count = count + 1; } return count; }
    async func immediate() { return 9; }
    async func infinite() { while (true) {} }
    async func load(path) { var result = await __adaTaskFromOperation(__adaAssets.begin(["loadAsync", path])); return result.value(); }
}
