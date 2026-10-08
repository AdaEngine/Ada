/// AdaScript conveniences installed in every runtime before authored sources.
enum AdaScriptStandardLibrary {
    static let source = """
    // The VM's native print closure does not forward all arguments through apply().
    func print() {
        for (var value in _args) { System.put(value); }
        System.print();
    }
    func put() {
        for (var value in _args) { System.put(value); }
    }
    func input(removeTrailingNewline = true) { return System.input(removeTrailingNewline); }
    func nanotime() { return System.nanotime(); }
    func exit(code = 0) { return System.exit(code); }

    func assert(condition, message = "Assertion failed") {
        if (!condition) { Fiber.abort(message); }
    }

    func __adaMathClamp(value, minimum, maximum) {
        assert(minimum <= maximum, "Math.clamp requires minimum <= maximum");
        return Math.min(Math.max(value, minimum), maximum);
    }

    func __adaMathSaturate(value) { return __adaMathClamp(value, 0, 1); }

    func __adaMathAddVector(left, right) {
        assert(left is List && right is List && left.count == right.count && left.count > 0,
               "Math.addVector requires nonempty vectors of equal length");
        var result = [];
        for (var index in 0..<left.count) { result.push(left[index] + right[index]); }
        return result;
    }

    func __adaMathSubtractVector(left, right) {
        assert(left is List && right is List && left.count == right.count && left.count > 0,
               "Math.subtractVector requires nonempty vectors of equal length");
        var result = [];
        for (var index in 0..<left.count) { result.push(left[index] - right[index]); }
        return result;
    }

    func __adaMathScaleVector(vector, scalar) {
        assert(vector is List && vector.count > 0, "Math.scaleVector requires a nonempty vector");
        var result = [];
        for (var component in vector) { result.push(component * scalar); }
        return result;
    }

    func __adaMathDot(left, right) {
        assert(left is List && right is List && left.count == right.count && left.count > 0,
               "Math.dot requires nonempty vectors of equal length");
        var result = 0.0;
        for (var index in 0..<left.count) { result += left[index] * right[index]; }
        return result;
    }

    func __adaMathCross(left, right) {
        assert(left is List && right is List && left.count == 3 && right.count == 3,
               "Math.cross requires two 3D vectors");
        return [
            left[1] * right[2] - left[2] * right[1],
            left[2] * right[0] - left[0] * right[2],
            left[0] * right[1] - left[1] * right[0]
        ];
    }

    func __adaMathLength(vector) { return Math.sqrt(__adaMathDot(vector, vector)); }

    func __adaMathNormalize(vector) {
        var magnitude = __adaMathLength(vector);
        assert(magnitude > 0, "Math.normalize requires a nonzero vector");
        var result = [];
        for (var component in vector) { result.push(component / magnitude); }
        return result;
    }

    func __adaMathDistance(left, right) {
        assert(left is List && right is List && left.count == right.count && left.count > 0,
               "Math.distance requires nonempty vectors of equal length");
        var difference = [];
        for (var index in 0..<left.count) { difference.push(left[index] - right[index]); }
        return __adaMathLength(difference);
    }

    func __adaMathLerpVector(left, right, amount) {
        assert(left is List && right is List && left.count == right.count && left.count > 0,
               "Math.lerpVector requires nonempty vectors of equal length");
        var result = [];
        for (var index in 0..<left.count) {
            result.push(Math.lerp(left[index], right[index], amount));
        }
        return result;
    }

    func __adaMathClampVector(vector, minimum, maximum) {
        assert(vector is List && minimum is List && maximum is List &&
               vector.count == minimum.count && vector.count == maximum.count && vector.count > 0,
               "Math.clampVector requires nonempty vectors of equal length");
        var result = [];
        for (var index in 0..<vector.count) {
            result.push(__adaMathClamp(vector[index], minimum[index], maximum[index]));
        }
        return result;
    }

    func __adaMathIdentityMatrix(size) {
        assert(size > 0, "Math.identityMatrix requires a positive size");
        var result = [];
        for (var row in 0..<size) {
            var values = [];
            for (var column in 0..<size) { values.push(row == column ? 1.0 : 0.0); }
            result.push(values);
        }
        return result;
    }

    func __adaMathTransposeMatrix(matrix) {
        assert(matrix is List && matrix.count > 0 && matrix[0] is List && matrix[0].count > 0,
               "Math.transposeMatrix requires a nonempty matrix");
        var result = [];
        for (var column in 0..<matrix[0].count) {
            var values = [];
            for (var row in 0..<matrix.count) {
                assert(matrix[row] is List && matrix[row].count == matrix[0].count,
                       "Math.transposeMatrix requires equal row lengths");
                values.push(matrix[row][column]);
            }
            result.push(values);
        }
        return result;
    }

    func __adaMathTransformVector(matrix, vector) {
        assert(matrix is List && matrix.count > 0 && vector is List && vector.count > 0,
               "Math.transformVector requires a nonempty matrix and vector");
        var result = [];
        for (var row in matrix) { result.push(__adaMathDot(row, vector)); }
        return result;
    }

    func __adaMathMultiplyMatrix(left, right) {
        assert(left is List && left.count > 0 && right is List && right.count > 0,
               "Math.multiplyMatrix requires nonempty matrices");
        var columns = __adaMathTransposeMatrix(right);
        var result = [];
        for (var row in left) {
            var values = [];
            for (var column in columns) { values.push(__adaMathDot(row, column)); }
            result.push(values);
        }
        return result;
    }

    """
}
