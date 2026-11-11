bump: minor

- A session that fails because its host does not know the model stops the host, as a spend limit
  or an auth error does: `_host.py` reads claude's `unrecognized_model` ("There's an issue with
  the selected model") and Codex's `model_not_found` as the cause `model`. The unattended loop
  raises one escalation gate that names the model and the fix, and no session starts on that host
  until it clears. Before, each item on a bad model spent its attempts and raised its own gate
  (gh#169 made those failures count).
