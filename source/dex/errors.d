/// Framework exceptions.
module dex.errors;

import dex.http : reasonPhrase;

/// An exception carrying an HTTP status code.
///
/// Throw this from a handler to produce a specific client/server error:
/// ---
/// throw new HttpError(404, "No such user");
/// ---
class HttpError : Exception
{
    /// HTTP status code sent to the client.
    int status;

    this(int status, string message = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this.status = status;
        super(message.length ? message : reasonPhrase(status), file, line, next);
    }
}
