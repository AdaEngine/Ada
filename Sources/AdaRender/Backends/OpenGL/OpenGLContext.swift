//
//  OpenGLContext.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

#if OPENGL

    #if WASM
        import WebGL
    #endif
    #if DARWIN

        #if canImport(AppKit)
            import AppKit
        #endif

        import OpenGL.GL3
    #else
        import OpenGL
    #endif
    import Math

    extension OpenGLBackend {
        enum RenderError: Error {
            case windowAlreadyExists
            case windowNotFound
        }

        final class Context {
            private(set) var windows: [UIWindow.ID: RenderWindow] = [:]

            @MainActor
            func createWindow(
                _ windowId: UIWindow.ID,
                for surface: any RenderSurface,
                size: Math.SizeInt
            ) throws {
                guard self.windows[windowId] == nil else {
                    throw RenderError.windowAlreadyExists
                }

                let context = try surface.createGLContext()
                context.makeCurrent()
                self.windows[windowId] = RenderWindow(
                    size: size,
                    renderSurface: surface,
                    openGLContext: context
                )
            }

            @MainActor
            func resizeWindow(_ windowId: UIWindow.ID, newSize: Math.SizeInt) throws {
                guard var window = self.windows[windowId] else {
                    throw RenderError.windowNotFound
                }

                window.size = newSize
                try window.openGLContext.resize(to: newSize)
                self.windows[windowId] = window
            }

            @MainActor
            func destroyWindow(_ windowId: UIWindow.ID) throws {
                guard self.windows[windowId] != nil else {
                    throw RenderError.windowNotFound
                }

                self.windows[windowId] = nil
            }
        }
    }

    extension OpenGLBackend.Context {
        struct RenderWindow {
            var size: Math.SizeInt
            let renderSurface: any RenderSurface
            let openGLContext: OpenGLContext
        }
    }

    protocol OpenGLContext: AnyObject {
        func makeCurrent()

        func flushBuffer()

        func resize(to size: Math.SizeInt) throws
    }

    extension RenderSurface {
        @MainActor
        private func createGLContext() throws -> OpenGLContext {
            #if DARWIN
                #if canImport(AppKit)
                    var attributes: [NSOpenGLPixelFormatAttribute] = [
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFAClosestPolicy),
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
                        NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion4_1Core),
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 32,
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), 24,
                        NSOpenGLPixelFormatAttribute(NSOpenGLPFAStencilSize), 8,
                        NSOpenGLPixelFormatAttribute(0),
                    ]
                    guard let format = NSOpenGLPixelFormat(attributes: &attributes) else {
                        fatalError("Failed to create OpenGL pixel format")
                    }

                    reportOpenGLError()

                    guard let context = NSOpenGLContext(format: format, share: nil) else {
                        preconditionFailure("Failed to create an OpenGL context.")
                    }
                    (self as! MetalView).colorPixelFormat = .bgra8Unorm
                    context.view = self as! MetalView

                    context.makeCurrentContext()

                    return context
                #else
                    fatalErrorMethodNotImplemented()
                #endif
            #elseif WASM
                fatalErrorMethodNotImplemented()
            #elseif os(Windows)
                fatalErrorMethodNotImplemented()
            #else
                fatalErrorMethodNotImplemented()
            #endif
        }
    }

    #if canImport(AppKit)
        extension NSOpenGLContext: OpenGLContext {
            func makeCurrent() {
                OpenGLBackend.currentContext = self
                self.makeCurrentContext()
                reportOpenGLError()
            }

            func resize(to size: Math.SizeInt) throws {
                guard let cglContext = self.cglContextObj else {
                    assertionFailure("CGLContext is not set")
                    return
                }
                var params = [GLint(size.width), GLint(size.height)]
                CGLSetParameter(cglContext, kCGLCPSurfaceBackingSize, &params)
                CGLEnable(cglContext, kCGLCESurfaceBackingSize)
                try checkOpenGLError()
            }
        }
    #endif

#endif
