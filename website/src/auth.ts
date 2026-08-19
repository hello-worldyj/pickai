import { jwtVerify, createRemoteJWKSet } from "jose";

const FIREBASE_PROJECT_ID = "picky-ai";
const ISSUER = `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`;

// Google's public signing keys for Firebase ID tokens — jose caches these across requests
// within a Worker isolate's lifetime rather than fetching on every single call.
const JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com")
);

export class AuthError extends Error {}

/** Verifies a Firebase ID token and returns the signed-in user's UID. */
export async function verifyFirebaseToken(token: string): Promise<string> {
  let payload;
  try {
    ({ payload } = await jwtVerify(token, JWKS, {
      issuer: ISSUER,
      audience: FIREBASE_PROJECT_ID,
    }));
  } catch {
    throw new AuthError("Invalid or expired token");
  }
  if (typeof payload.sub !== "string" || !payload.sub) {
    throw new AuthError("Token missing subject");
  }
  return payload.sub;
}

export function extractBearerToken(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length);
}
