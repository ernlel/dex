/// Express-inspired web framework for D.
module dex;

public import dex.app : App;
public import dex.errors : HttpError;
public import dex.http : TrustProxy;
public import dex.jsonx : fromJSONValue, optional, toJSONValue;
public import dex.middleware : CompressionOptions, CorsOptions, RateLimitOptions, SecurityOptions, SessionOptions,
                              StaticOptions, bodyLimit, compression, cors, logger, rateLimit, securityHeaders,
                              serveStatic, session;
public import dex.request : Request;
public import dex.response : Response, CookieOptions, SameSite;
public import dex.router : ErrorHandler, Handler, Middleware, Next, ParamHandler, RouteChain, Router;
public import dex.session : MemorySessionStore, Session, SessionStore, signCookie, unsignCookie;
public import dex.view : TemplateException, ViewRenderer, renderTemplate, renderTemplateFile;

/// Helper function to create a new `App` instance: `auto app = dex.app();`
App app()
{
    return new App;
}
