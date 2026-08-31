# MacPaw OpenAI 0.5.1 async interception contribution

Latchway cannot safely attach a short-lived DPoP authorization proof through
MacPaw/OpenAI 0.5.1's synchronous middleware boundary. This directory carries
the upstream-ready change that adds ordered asynchronous request interception
without changing the existing synchronous fast path.

## Pinned upstream

- Repository: `https://github.com/MacPaw/OpenAI.git`
- Release: `0.5.1`
- Base commit: `a532be89be9a30ec003e4ba0974a52a88d26fc6d`
- Patch commit: `4fab05ce89ef6c454caa8ec9f1f4cfba0581cc3d`
- Patch SHA-256: `8035958648cc19a3ce9dae7e86f2d872cd3353c7f16adf06359330c413f53411`

The patch covers callback, async/await, Combine, and streaming clients. It
preserves middleware order and bridges cancellation both before and after the
underlying request is dispatched.

## Reproduce

```bash
git clone https://github.com/MacPaw/OpenAI.git macpaw-openai
git -C macpaw-openai checkout a532be89be9a30ec003e4ba0974a52a88d26fc6d
git -C macpaw-openai am /absolute/path/to/0001-Add-asynchronous-request-interception.patch
swift test --package-path macpaw-openai
```

The verified run on 2026-08-31 passed 187 XCTest tests and 30 Swift Testing
tests. Five of the Swift Testing cases are the new ordering, callback,
async/await, streaming, and cancellation coverage in this contribution.

No external pull request is represented by this artifact. Opening or merging
an upstream pull request requires separate maintainer authority.
