# Step 3 media controls (retired renders)

The 68 pt card, marquee, stack mask and hover-fill scenes were retired by
capture session 2. Their renders and generators are removed with the code and
checks. Current synthetic scenes and verification: [Step 3b](../step3b/README.md).
Historical check and benchmark receipts remain in [evidence](evidence/).
[Scroll investigation and A/A control method](evidence/scroll-investigation/README.md).

The main-branch tooltip token fix (#113) is inherited by Step 3b. Its two
Step 3 tooltip rerenders are retired with the rest of the 68 pt card fixtures;
current tooltip scenes use the Step 3b generator and the inherited token.
