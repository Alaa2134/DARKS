import { Router } from "express";
import { runCtfOp, type CtfOp } from "../services/ctfTools";

export const ctfRouter = Router();

const OPS: CtfOp[] = [
  "base64-encode",
  "base64-decode",
  "hex-encode",
  "hex-decode",
  "url-encode",
  "url-decode",
  "rot13",
  "binary-decode",
  "reverse",
  "caesar",
  "vigenere-decode",
  "hash-identify",
  "jwt-decode",
];

ctfRouter.get("/ops", (_req, res) => {
  res.json({ ops: OPS });
});

/** POST /api/ctf/transform — body: { op, input, param? } */
ctfRouter.post("/transform", (req, res) => {
  const op = req.body?.op as CtfOp;
  const input = typeof req.body?.input === "string" ? req.body.input : "";
  const param = typeof req.body?.param === "string" ? req.body.param : undefined;
  if (!OPS.includes(op)) {
    return res.status(400).json({ error: "unknown op" });
  }
  res.json(runCtfOp(op, input, param));
});
