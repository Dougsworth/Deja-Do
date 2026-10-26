import Foundation

/// Whether a step changes something that can't simply be undone: sending,
/// saving, submitting, deleting, paying. Risky steps are never repeated,
/// never clicked by a guessed position, and an AI pick for one is confirmed
/// first, because doing one twice or in the wrong place is the worst outcome.
public enum StepRisk: String, Codable, CaseIterable {
    case normal
    case risky
}

public struct RiskGuess: Equatable {
    public let risk: StepRisk
    /// Why, in a few words, for the step list.
    public let reason: String?

    public init(risk: StepRisk, reason: String?) {
        self.risk = risk
        self.reason = reason
    }
}

/// Guesses which steps are risky from their labels and keys.
///
/// The word list and the "icon only click after the last typing commits the
/// record" rule come from OpenAdapt's risk classifier (openadapt_flow/risk.py,
/// MIT licence, Copyright (c) 2026 OpenAdapt.AI). It errs towards risky:
/// a false "risky" only means Deja Do stops instead of retrying; a false
/// "normal" could send something twice.
public enum RiskGuesser {
    // Words that commit something to someone else or can't be taken back.
    // OpenAdapt's list also has add, insert, apply, update, create and accept;
    // those are left out here because they name everyday, undoable buttons
    // (Calculator's + is "Add") and a false "risky" stops runs for nothing.
    static let writeStems = [
        "sav(?:e|es|ing)", "submit(?:s|ted|ting)?", "confirm(?:s|ed|ing)?", "delet(?:e|es|ing)", "remov(?:e|es|ing)",
        "send(?:s|ing)?", "reply", "reply all", "post", "publish(?:es|ed|ing)?", "pay(?:s|ing|ment)?",
        "sign[\\s\\-_]?up", "signup", "(?:co[\\-_]?|e[\\-_]?)?sign(?:s|ed|ing)?(?![\\s\\-_]*(?:in|on|out)\\b)",
        "regist(?:er|ers|ering|ration)", "enroll(?:s|ed|ing|ment)?", "approv(?:e|es|ed|ing)", "transfer(?:s|red|ring)?",
        "upload(?:s|ed|ing)?", "overwrit(?:e|es|ing)", "discard(?:s|ed|ing)?", "archiv(?:e|es|ing)",
        "finaliz(?:e|es|ing)", "finalise", "checkout", "check[\\s\\-_]?out", "purchas(?:e|es|ing)",
        "place[\\s\\-_]order", "order now", "buy", "book now", "trash", "empty trash", "move to bin", "share", "invite",
        "export(?:s|ed|ing)?", "unsubscribe", "cancel (?:order|subscription|booking|appointment)"
    ]
    static let writeRE = try! NSRegularExpression(
        pattern: "\\b(?:" + writeStems.joined(separator: "|") + ")\\b", options: [.caseInsensitive])

    static let returnKeys: Set<UInt16> = [36, 76]
    static let deleteKeys: Set<UInt16> = [51, 117]
    static let commandFlag: UInt64 = 0x00100000

    /// The guess for one step in its task.
    public static func guess(_ steps: [Step], at index: Int) -> RiskGuess {
        guard steps.indices.contains(index) else { return RiskGuess(risk: .normal, reason: nil) }
        let step = steps[index]
        switch step.kind {
        case .click(let t, _, _, _):
            let text = [t.label, t.title, t.desc, t.help, t.visual?.clickedText?.text].compactMap { $0 }.joined(separator: " ")
            if let word = firstWriteWord(in: text) {
                return RiskGuess(risk: .risky, reason: "Looks like it \(verbPhrase(word))")
            }
            // An unlabelled button right after typing into a form usually saves or sends it.
            let hasText = !text.trimmingCharacters(in: .whitespaces).isEmpty || t.hasText
            if !hasText, let lastTyping = steps.lastIndex(where: { if case .type = $0.kind { return true }; return false }),
               lastTyping < index,
               !steps[(lastTyping + 1)..<index].contains(where: { if case .click = $0.kind { return true }; return false }) {
                return RiskGuess(risk: .risky, reason: "An unlabelled button after typing, probably sends or saves")
            }
            return RiskGuess(risk: .normal, reason: nil)
        case .key(let code, let mods, _):
            let command = mods & commandFlag != 0
            if returnKeys.contains(code) {
                if command { return RiskGuess(risk: .risky, reason: "⌘ Return usually sends") }
                let previous = steps[..<index].last { $0.isEnabled }
                if let previous, case .type = previous.kind {
                    return RiskGuess(risk: .risky, reason: "Return after typing usually sends or submits")
                }
            }
            if command && code == 1 { return RiskGuess(risk: .risky, reason: "⌘S saves") }
            if command && deleteKeys.contains(code) { return RiskGuess(risk: .risky, reason: "⌘ Delete deletes") }
            if !command && deleteKeys.contains(code) {
                let previous = steps[..<index].last { $0.isEnabled }
                if let previous, case .click = previous.kind {
                    return RiskGuess(risk: .risky, reason: "Delete on something selected")
                }
            }
            return RiskGuess(risk: .normal, reason: nil)
        default:
            return RiskGuess(risk: .normal, reason: nil)
        }
    }

    /// The same idea in Spanish, French, German, Portuguese, Italian and Dutch,
    /// written without accents because labels are compared after folding them.
    /// Words that also mean "clear" (borrar, effacer, apagar, cancella) are left
    /// out, so a calculator's clear key in those languages isn't flagged.
    static let otherLanguages: [String: String] = {
        var m: [String: String] = [:]
        func add(_ kind: String, _ words: String) { for w in words.split(separator: ",") { m[String(w)] = kind } }
        add("send", "enviar,envia,envie,envoyer,envoie,senden,absenden,abschicken,invia,inviare,verzenden,versturen,verstuur,responder,repondre,antworten,rispondi,beantwoorden,publicar,publier,veroffentlichen,pubblica,publiceren,compartir,partager,teilen,condividi,compartilhar,partilhar,delen,invitar,inviter,einladen,invita,convidar,uitnodigen")
        add("delete", "eliminar,supprimer,loschen,entfernen,elimina,excluir,verwijderen,descartar,abandonner,verwerfen,scarta,archivar,archiver,archivieren,archivia,arquivar,archiveren")
        add("pay", "pagar,payer,bezahlen,zahlen,paga,betalen,comprar,acheter,kaufen,acquista,kopen,bestellen,commander,ordina,transferir,transferer,uberweisen,trasferisci,overmaken")
        add("save", "guardar,enregistrer,sauvegarder,speichern,sichern,salva,salvare,salvar,opslaan,exportar,exporter,exportieren,esporta,exporteren")
        add("submit", "confirmar,confirmer,valider,bestatigen,conferma,bevestigen,soumettre,einreichen,indienen,aprobar,approuver,genehmigen,approva,aprovar,goedkeuren,registrarse,inscrire,registrieren,registrati,cadastrar,registreren")
        return m
    }()

    static func firstWriteWord(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = writeRE.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
            return String(text[r]).lowercased()
        }
        for word in TextSimilarity.tokens(TextSimilarity.normalize(text)) where otherLanguages[word] != nil {
            return word
        }
        return nil
    }

    static func verbPhrase(_ word: String) -> String {
        let w = word.lowercased()
        switch otherLanguages[w] {
        case "send": return "sends something (“\(word)”)"
        case "delete": return "deletes something (“\(word)”)"
        case "pay": return "pays or orders (“\(word)”)"
        case "save": return "saves a file (“\(word)”)"
        case "submit": return "submits or changes something (“\(word)”)"
        default: break
        }
        if w.hasPrefix("send") || w == "reply" || w == "post" || w.hasPrefix("publish") || w == "share" || w == "invite" { return "sends something" }
        if w.hasPrefix("delet") || w.hasPrefix("remov") || w == "trash" || w == "empty" || w.hasPrefix("discard") || w == "move to bin" { return "deletes something" }
        if w.hasPrefix("pay") || w.hasPrefix("purchas") || w.contains("order") || w.contains("check") || w == "book" || w.hasPrefix("transfer") { return "pays or orders" }
        if w.hasPrefix("sav") || w.hasPrefix("export") || w.hasPrefix("download") || w.hasPrefix("overwrit") { return "saves a file" }
        return "submits or changes something (“\(word)”)"
    }
}

extension Automation {
    /// The step's risk: the person's choice if they made one, else the guess.
    public func risk(at index: Int) -> RiskGuess {
        guard steps.indices.contains(index) else { return RiskGuess(risk: .normal, reason: nil) }
        if let set = steps[index].risk {
            return RiskGuess(risk: set, reason: set == .risky ? "Marked as risky" : nil)
        }
        return RiskGuesser.guess(steps, at: index)
    }
}
