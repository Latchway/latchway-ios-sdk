# OpenAI-compatible streaming

The Latchway SDK is transport-oriented and does not own AI request models. The
example uses an ordinary OpenAI-compatible JSON body and streams the response
incrementally. The feature selects server-owned routing; the client does not
send a physical provider model or credential.
