//
//  OpenGLShader.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

#if OPENGL

    #if WASM
        import WebGL
    #endif
    #if DARWIN
        import OpenGL.GL3
    #else
        import OpenGL
    #endif

    final class OpenGLShader: CompiledShader {
        enum GLError: Error {
            case shaderCompilationError
        }

        let shader: GLuint

        init(shader: Shader) throws {
            let spirvShader = try shader.spirvCompiler.compile()
            let glShader = glCreateShader(shader.stage.glType)

            spirvShader.source.withCString { pointer in
                var ptr: UnsafePointer<GLchar>? = UnsafePointer<GLchar>(pointer)
                return glShaderSource(glShader, 1, &ptr, nil)
            }

            glCompileShader(glShader)

            var result: GLint = 0
            glGetShaderiv(glShader, GLenum(GL_COMPILE_STATUS), &result)

            if result == 0 {
                var infoLogLength: GLint = 0
                glGetShaderiv(glShader, GLenum(GL_INFO_LOG_LENGTH), &infoLogLength)

                if infoLogLength > 0 {
                    var infoLog = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(infoLogLength))
                    glGetShaderInfoLog(glShader, GLsizei(infoLogLength), nil, &infoLog)
                    let errorMessage = String(cString: infoLog)
                    assertionFailure("Shader compilation failed: \(errorMessage)")
                    infoLog.deallocate()
                    // throw GLError.shaderCompilationError
                }
                assertionFailure("Shader compilation failed")
                // throw GLError.shaderCompilationError
            }

            self.shader = glShader
        }

        deinit {
            glDeleteShader(self.shader)
        }
    }

    extension ShaderStage {
        private var glType: GLenum {
            switch self {
            case .vertex:
                return GLenum(GL_VERTEX_SHADER)
            case .fragment:
                return GLenum(GL_FRAGMENT_SHADER)
            case .compute:
                #if DARWIN
                    fatalErrorMethodNotImplemented()
                #else
                    return GLenum(GL_COMPUTE_SHADER)
                #endif
            case .tesselationControl:
                return GLenum(GL_TESS_CONTROL_SHADER)
            case .tesselationEvaluation:
                return GLenum(GL_TESS_EVALUATION_SHADER)
            case .max:
                return .max
            }
        }
    }

    final class OpenGLProgram: @unchecked Sendable {
        let program: GLuint
        private var shaders: [OpenGLShader] = []

        init() {
            self.program = glCreateProgram()
        }

        func attach(to shader: OpenGLShader) {
            glAttachShader(program, shader.shader)
            shaders.append(shader)

            reportOpenGLError()
        }

        func isLinked() -> Bool {
            var result: GLint = 0
            glGetProgramiv(program, GLenum(GL_LINK_STATUS), &result)
            return result != 0
        }

        func link() {
            glLinkProgram(program)
        }

        func use() {
            glUseProgram(program)
        }

        func validate() {
            glValidateProgram(program)
        }

        func unuse() {
            glUseProgram(0)
        }

        deinit {
            glDeleteProgram(program)
        }
    }

#endif
