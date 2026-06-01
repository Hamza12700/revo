# contributing

thank you for considering contributing to revo

the project is so young, that even taking a stroll through any source file might yield you a good observation

a contribution anything from a pull request to an issue or a suggestion, all contributions are welcome!

## where to start

- check out [TODO.md](./TODO.md) for plans and pick an issue
- open an issue on github and fork
- create branch on your fork by doing

```bash
git checkout -b <issue_number>-<issue_description>
```

- after you have implemented fully the issue, make a pull request

```bash
git add .
git commit -m "Fixed #<issue_number>: <issue_description>"
git push origin <issue_number>-<issue_description>
```

- if you're adding an std function, please add a doc-comment that can get parsed by `scripts/docgen.py`

## about AI-generated code

please do not submit LLM-authored code if you do not understand it, can't explain it or have not tested it
do not submit english AI-generated or translated text at all. this goes for issues as well
if you don't know the language - that's fine, just submit it in your native language and i'll translate it manually
do not submit walls of AI-generated code and instead describe it in your own words
this greatly reduces maintenance burden

if you submit an AI-assisted or AI-generated pull request, clearly mark it as such

do not advertise in git history - that is, do not leave a model/vendor name in the details

if you make a functional change, the correctness should also be verified by a test
