//
//  DictionaryModels.swift
//  Nova
//

import Foundation
import FirebaseFirestore

// MARK: - Helper Models

public struct SortRule: Identifiable, Hashable, Codable {
    public var id: String = UUID().uuidString
    public var field: String // "createdAt", "term", "learningStage"
    public var direction: String // "asc", "desc"
    
    public init(id: String = UUID().uuidString, field: String, direction: String) {
        self.id = id
        self.field = field
        self.direction = direction
    }
}

public struct CustomListModel: Identifiable, Codable {
    public let id: String
    public let name: String
    public let wordIds: [String]
    public let userId: String
    
    public init(id: String, name: String, wordIds: [String], userId: String) {
        self.id = id
        self.name = name
        self.wordIds = wordIds
        self.userId = userId
    }
}

public struct StickyNoteModel: Identifiable {
    public let id: String
    public let title: String
    public let text: String
    public let wordTerm: String
    public let wordId: String
    public let createdAt: Date
    
    public init(id: String, title: String, text: String, wordTerm: String, wordId: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.text = text
        self.wordTerm = wordTerm
        self.wordId = wordId
        self.createdAt = createdAt
    }
}

// MARK: - Word Detail Sub-Models

public struct WordMeaning: Identifiable {
    public let id = UUID()
    public let definition: String
    public let examples: [WordExample]
    
    public init(definition: String, examples: [WordExample]) {
        self.definition = definition
        self.examples = examples
    }
}

public struct WordExample: Identifiable {
    public let id = UUID()
    public let en: String
    public let tr: String
    
    public init(en: String, tr: String) {
        self.en = en
        self.tr = tr
    }
}

public struct WordRelation: Identifiable {
    public let id = UUID()
    public let word: String
    public let meaning: String
    
    public init(word: String, meaning: String) {
        self.word = word
        self.meaning = meaning
    }
}

// MARK: - Local Word Model Struct Definition

public struct LocalWord: Identifiable {
    public let id: String
    public let term: String
    public let shortMeanings: String
    public let pronunciation: String
    public let level: String
    public var isStarred: Bool
    public var learningStage: Int
    public let createdAt: Date
    public let language: String // E.g., "english"
    
    // Additional fields for detail view
    public var meanings: [WordMeaning]? = nil
    public var synonyms: [WordRelation]? = nil
    public var antonyms: [WordRelation]? = nil
    public var collocations: [String]? = nil
    public var wordFamily: [String]? = nil
    public var specialNote: String? = nil
    public var conjugation: String? = nil
    
    public init(
        id: String,
        term: String,
        shortMeanings: String,
        pronunciation: String,
        level: String,
        isStarred: Bool,
        learningStage: Int,
        createdAt: Date,
        language: String,
        meanings: [WordMeaning]? = nil,
        synonyms: [WordRelation]? = nil,
        antonyms: [WordRelation]? = nil,
        collocations: [String]? = nil,
        wordFamily: [String]? = nil,
        specialNote: String? = nil,
        conjugation: String? = nil
    ) {
        self.id = id
        self.term = term
        self.shortMeanings = shortMeanings
        self.pronunciation = pronunciation
        self.level = level
        self.isStarred = isStarred
        self.learningStage = learningStage
        self.createdAt = createdAt
        self.language = language
        self.meanings = meanings
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.collocations = collocations
        self.wordFamily = wordFamily
        self.specialNote = specialNote
        self.conjugation = conjugation
    }
    
    public var meaningsList: [String] {
        if shortMeanings.contains("\n") {
            return shortMeanings.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if shortMeanings.contains(",") {
            return shortMeanings.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return [shortMeanings.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }
    }
}

// MARK: - Practice & Quiz Models

public struct PracticeQuestionItem: Identifiable {
    public let id: String
    public let wordId: String
    public let targetWord: LocalWord
    public let questionType: String // "mcq", "tf", "flashcard", "written"
    public let prompt: String
    public let correctAnswer: String
    public let options: [String]
    public let isTrueStatement: Bool?
    public let statement: String?
    public let exampleSentence: String?
    public let turkishTranslation: String?
    
    public init(
        id: String,
        wordId: String,
        targetWord: LocalWord,
        questionType: String,
        prompt: String,
        correctAnswer: String,
        options: [String],
        isTrueStatement: Bool? = nil,
        statement: String? = nil,
        exampleSentence: String? = nil,
        turkishTranslation: String? = nil
    ) {
        self.id = id
        self.wordId = wordId
        self.targetWord = targetWord
        self.questionType = questionType
        self.prompt = prompt
        self.correctAnswer = correctAnswer
        self.options = options
        self.isTrueStatement = isTrueStatement
        self.statement = statement
        self.exampleSentence = exampleSentence
        self.turkishTranslation = turkishTranslation
    }
}

public struct QuestionAnswerResult {
    public let wordId: String
    public let wordTerm: String
    public let questionPrompt: String
    public let correctAnswer: String
    public let userAnswer: String
    public let isCorrect: Bool
    public var isTypo: Bool = false
    public var isWordFamily: Bool = false
    
    public init(
        wordId: String,
        wordTerm: String,
        questionPrompt: String,
        correctAnswer: String,
        userAnswer: String,
        isCorrect: Bool,
        isTypo: Bool = false,
        isWordFamily: Bool = false
    ) {
        self.wordId = wordId
        self.wordTerm = wordTerm
        self.questionPrompt = questionPrompt
        self.correctAnswer = correctAnswer
        self.userAnswer = userAnswer
        self.isCorrect = isCorrect
        self.isTypo = isTypo
        self.isWordFamily = isWordFamily
    }
}

public struct QuickTestTemplate: Identifiable {
    public let id: String
    public let name: String
    public let questionCount: Int
    public let questionFormat: String
    public let selectedLanguage: String
    public let typeMCQ: Bool
    public let typeTF: Bool
    public let typeFlashcard: Bool
    public let typeWritten: Bool
    public let statusYeni: Bool
    public let statusOgreniyor: Bool
    public let statusOgrendi: Bool
    public let onlyStarred: Bool
    public let excludeStarred: Bool
    public let excludeSolvedToday: Bool
    public let shufflePool: Bool
    public let modeFillInTheBlanks: Bool
    public let smartDistractors: Bool
    public let modeMissingLetters: Bool
    public let modeSingleMeaning: Bool
    public let modeComboStreak: Bool
    public let modeProgressiveHint: Bool
    public var maxAllowedTypoLetters: Int = 2
    public var createdAt: Date = Date()
    
    public init(
        id: String,
        name: String,
        questionCount: Int,
        questionFormat: String,
        selectedLanguage: String,
        typeMCQ: Bool,
        typeTF: Bool,
        typeFlashcard: Bool,
        typeWritten: Bool,
        statusYeni: Bool,
        statusOgreniyor: Bool,
        statusOgrendi: Bool,
        onlyStarred: Bool,
        excludeStarred: Bool,
        excludeSolvedToday: Bool,
        shufflePool: Bool,
        modeFillInTheBlanks: Bool,
        smartDistractors: Bool,
        modeMissingLetters: Bool,
        modeSingleMeaning: Bool,
        modeComboStreak: Bool,
        modeProgressiveHint: Bool,
        maxAllowedTypoLetters: Int = 2,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.questionCount = questionCount
        self.questionFormat = questionFormat
        self.selectedLanguage = selectedLanguage
        self.typeMCQ = typeMCQ
        self.typeTF = typeTF
        self.typeFlashcard = typeFlashcard
        self.typeWritten = typeWritten
        self.statusYeni = statusYeni
        self.statusOgreniyor = statusOgreniyor
        self.statusOgrendi = statusOgrendi
        self.onlyStarred = onlyStarred
        self.excludeStarred = excludeStarred
        self.excludeSolvedToday = excludeSolvedToday
        self.shufflePool = shufflePool
        self.modeFillInTheBlanks = modeFillInTheBlanks
        self.smartDistractors = smartDistractors
        self.modeMissingLetters = modeMissingLetters
        self.modeSingleMeaning = modeSingleMeaning
        self.modeComboStreak = modeComboStreak
        self.modeProgressiveHint = modeProgressiveHint
        self.maxAllowedTypoLetters = maxAllowedTypoLetters
        self.createdAt = createdAt
    }
    
    public var testType: String {
        var types: [String] = []
        if typeWritten { types.append("Yazılı") }
        if typeMCQ { types.append("Çoktan Seçmeli") }
        if typeTF { types.append("Doğru/Yanlış") }
        if typeFlashcard { types.append("Flashcard") }
        return types.count > 1 ? "Karışık" : (types.first ?? "Yazılı")
    }
    
    public var lang: String { selectedLanguage }
    public var direction: String {
        questionFormat == "definition" ? "Türkçe -> Yabancı Dil" : (questionFormat == "term" ? "Yabancı Dil -> Türkçe" : "Karışık")
    }
    
    public var status: String {
        var arr: [String] = []
        if statusYeni { arr.append("Yeni") }
        if statusOgreniyor { arr.append("Öğreniyor") }
        if statusOgrendi { arr.append("Öğrendi") }
        return arr.isEmpty ? "Tümü" : arr.joined(separator: " + ")
    }
    
    public var starOption: String {
        onlyStarred ? "Sadece Yıldızlı" : (excludeStarred ? "Sadece Yıldızsız" : "Tümü")
    }
    
    public var features: String {
        var arr: [String] = []
        if modeFillInTheBlanks { arr.append("Örnek Cümle") }
        if smartDistractors { arr.append("Akıllı Şıklar") }
        if modeMissingLetters { arr.append("Eksik Harfler") }
        if modeSingleMeaning { arr.append("Tek Anlam") }
        if modeComboStreak { arr.append("Combo") }
        if modeProgressiveHint { arr.append("Kademeli İpucu") }
        if typeWritten { arr.append("Tolerans: \(maxAllowedTypoLetters) Harf") }
        return arr.isEmpty ? "Standart" : arr.joined(separator: ", ")
    }
}

// MARK: - Unsolved / Repetition Word Model

public struct UnsolvedWordItem: Identifiable {
    public let word: LocalWord
    public let lastSolvedDate: Date?
    public let daysSinceLastSolved: Int? // nil if never solved
    
    public var id: String { word.id }
    
    public init(word: LocalWord, lastSolvedDate: Date?, daysSinceLastSolved: Int?) {
        self.word = word
        self.lastSolvedDate = lastSolvedDate
        self.daysSinceLastSolved = daysSinceLastSolved
    }
}
