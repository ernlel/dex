/// Express-inspired web framework for D.
module dex;

public import dex.app : App;
public import dex.errors : HttpError;
public import dex.middleware : CompressionOptions, CorsOptions, SecurityOptions, StaticOptions,
                              compression, cors, logger, securityHeaders, serveStatic;
public import dex.request : Request;
public import dex.response : Response, CookieOptions, SameSite;
public import dex.router : ErrorHandler, Handler, Middleware, Next, Router;
public import dex.view : TemplateException, ViewRenderer, renderTemplate, renderTemplateFile;

/// Helper function to create a new `App` instance: `auto app = dex.app();`
App app()
{
    return new App;
}
