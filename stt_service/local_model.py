"""The cleanup model, run in this process on MLX."""

from __future__ import annotations

from pathlib import Path


class LocalModel:
    """Turns chat messages into the model's reply.

    MLX ties a model to the thread that loaded it, so load and call this on
    the same thread, as the speech model is.
    """

    def __init__(self, path: Path) -> None:
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler

        self.model, self.tokenizer = load(str(path))
        self.sampler = make_sampler(temp=0.2)

    def __call__(self, messages: list[dict]) -> str:
        from mlx_lm import generate

        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        return generate(self.model, self.tokenizer, prompt=prompt, max_tokens=1024, sampler=self.sampler)
