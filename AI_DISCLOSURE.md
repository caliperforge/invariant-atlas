# AI Disclosure — Exploit→Invariant Atlas

The Atlas is built and maintained by CaliperForge under an AI-augmented
authoring stack. This document is calm disclosure of which surfaces are
AI-touched and the review discipline that gates each one.

## What is AI-touched

- **Invariant proposals.** Candidate invariant predicates (the property
  prose, the Cairo / Rust / Move / Solidity property body) may be
  drafted by a Claude model (Sonnet 4.6 for pattern-recognition over
  ABI + storage layout; Opus 4.6 for judgment-heavy reconstruction).
  Every accepted invariant is reviewed and edited by the case author
  before being committed.
- **Same-source twins.** The reconstructed vulnerable code in each
  case's `clean/` and `planted/` subdirectories is authored by a
  CaliperForge specialist (Opus 4.6 for case 1 by `cairo_specialist`;
  Opus 4.6 for case 2 by `move_specialist`; Opus 4.6 for case 3 by
  `rust_anchor_specialist`; Opus 4.6 for case 4 by
  `rust_anchor_specialist`; Opus 4.7 for case 5 by
  `rust_anchor_specialist`; Opus 4.6 for case 6 by
  `solidity_specialist`) against the affected protocol's
  published post-mortem. The reconstruction is faithful to the
  post-mortem's described bug class; it is NOT a fork of the
  protocol team's production source.
- **READMEs and case write-ups.** Drafted with AI assistance; reviewed
  for the rubric at
  `agents/ai_ops/policies/content_qa_antiaiism_rubric.md`.

## What is NOT AI-touched

- The published post-mortem URLs themselves (carried as-cited).
- The CI verdict (pass / fail is a function of the snforge / forge /
  anchor / move run, not the model).
- The CEO-approved positioning paragraph (README.md "Related work and
  positioning") — that text is human-locked verbatim across surfaces.

## Audit trail

- Every case's `README.md` cites the primary public post-mortem URL.
- Every Atlas commit lists the author (Michael Moffett, operator at
  CaliperForge) and the case specialist who authored the
  reconstruction.
- The case's CI workflow output (clean + planted leg) is uploaded as
  an artifact on every push; the badges on the case README link to the
  most recent green run.

## Why we disclose

CaliperForge's identity register makes AI-augmented authorship the
default disclosure posture, not the exception. Reviewers should know
which content was AI-drafted so they can apply their own scrutiny at
that surface. See
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure)
for the org-level register.

## Contact

Operator: Michael Moffett — michael@caliperforge.com — team@caliperforge.com.
