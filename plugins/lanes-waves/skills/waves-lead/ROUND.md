# Waves lead: re-reviewing a fix round

Read this when you open the review-only PR for the "rescore rule".

All fixes of the round go in one review-only PR. Its base is the reviewed integration head. Its head is a child of that
base that carries the rebuilt tree:

```bash
git commit-tree <rebuilt head>^{tree} -p <reviewed head>
```

A rebuilt head's merge base is the base branch, so a PR opened from the rebuilt head itself shows the whole wave.
