"""Who is calling (C2). The caller is the object ID (oid) in a token the client itself acquired from Entra ID through
azure-identity, after validating that token's signature, audience, issuer, tenant and expiry.

The caller never comes from an environment variable, a command-line argument or anything the model produces. The only
operator setting is the expected tenant ID, which says which directory to trust, not who the caller is.

Caveat: an access token is meant for its resource (here https://ai.azure.com), and clients normally treat it as opaque.
Validating it here binds the tool to the identity the client signed in as; it isn't a server-side authorization check.
The authoritative fix is a service with its own identity that validates the user's token itself (finding, attack A13).
"""
from __future__ import annotations

SCOPE = "https://ai.azure.com/.default"
AUDIENCES = ("https://ai.azure.com", "https://ai.azure.com/")


class CallerValidationError(Exception):
    pass


def validated_caller_oid(credential, tenant_id: str, *, jwks_client=None, scope: str = SCOPE,
                         audiences: tuple[str, ...] = AUDIENCES) -> str:
    """Acquire a token with `credential` and return its validated oid claim."""
    import jwt  # PyJWT, imported here so modules that don't need it load without it

    if not tenant_id:
        raise CallerValidationError("expected tenant ID is required")
    token = credential.get_token(scope).token
    jwks_client = jwks_client or jwt.PyJWKClient(f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys")
    try:
        signing_key = jwks_client.get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=list(audiences),
            issuer=[f"https://sts.windows.net/{tenant_id}/", f"https://login.microsoftonline.com/{tenant_id}/v2.0"],
            options={"require": ["exp", "iat", "aud", "iss", "oid", "tid"]},
        )
    except jwt.PyJWTError as exc:
        raise CallerValidationError(f"token validation failed: {type(exc).__name__}") from None
    if claims.get("tid") != tenant_id:
        raise CallerValidationError("token is from a different tenant")
    return claims["oid"]
