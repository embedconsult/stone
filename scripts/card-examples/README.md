# Card examples

Each directory has a `build.sh` that takes an empty directory and makes its Fossil repositories there. It needs a POSIX shell and `fossil`. `now.txt` fixes the clock. `cards/` holds the JSON of the `card/NAME` wiki pages created in the definitions repository. `expected/NAME.json` holds the answer to `card NAME` for login `stone`, with every `.fossil` in that directory read together and `a.fossil` as `--definitions`.

Stone's C bridge can run each builder, answer each card from the made repositories at the time in `now.txt`, and compare parsed JSON with the matching expected file. The order of items matters. The example includes two projects with records and one repository with no forum post. Its `milestones` card shows that a repository without a `due` column contributes no items; `b.fossil` has that column. The stored check-in tags are made by Fossil both with `--raw` and without it.

The forum posts and tickets are reconstructed from Fossil artifacts; check-ins, tags, and wiki pages use Fossil commands. The `recent` card finds two threads, reports a count of two, and shows one item because its limit is one. The Crystal spec rebuilds every repository and checks that every card still answers the same way.

## In Stone

Copied unchanged from ollama check-in [973aca3f4c](https://ollama.openbeagle.org/ollama/info/973aca3f4c), `spec/cards/examples/`, without the `*.schema.json` files that the ollama repository requires next to each JSON file. `scripts/linux-crosslink-test.sh` builds each example with the generated Fossil and runs `scripts/linux-cards-driver.c` on it, before and after `fossil rebuild`. When OCX changes its examples, copy them again.
