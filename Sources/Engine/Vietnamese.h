//
//  Vietnamese.h
//  OpenKey
//
//  Created by Tuyen on 1/19/19.
//  Copyright © 2019 Tuyen Mai. All rights reserved.
//

#ifndef Vietnamese_h
#define Vietnamese_h
#include "DataType.h"
#include <vector>
#include <map>
#include <string>
#include <utility>

// Wrapper structs to avoid heap allocations and dynamic initializations of maps/vectors
struct Array16 {
    const Uint16* data;
    size_t count;

    size_t size() const { return count; }
    Uint16 operator[](size_t idx) const { return data[idx]; }
    const Uint16* begin() const { return data; }
    const Uint16* end() const { return data + count; }
};

struct Array2D16 {
    const Array16* rows;
    size_t count;

    size_t size() const { return count; }
    const Array16& operator[](size_t idx) const { return rows[idx]; }
    const Array16* begin() const { return rows; }
    const Array16* end() const { return rows + count; }
};

struct Array32 {
    const Uint32* data;
    size_t count;

    size_t size() const { return count; }
    Uint32 operator[](size_t idx) const { return data[idx]; }
    const Uint32* begin() const { return data; }
    const Uint32* end() const { return data + count; }
};

struct Array2D32 {
    const Array32* rows;
    size_t count;

    size_t size() const { return count; }
    const Array32& operator[](size_t idx) const { return rows[idx]; }
    const Array32* begin() const { return rows; }
    const Array32* end() const { return rows + count; }
};

// Vowel Map representation
struct VowelMapEntry {
    Uint16 key;
    Array2D16 vowelSet;
};

class VowelMap {
public:
    const VowelMapEntry* entries;
    size_t count;

    Array2D16 operator[](Uint16 key) const {
        for (size_t i = 0; i < count; ++i) {
            if (entries[i].key == key) {
                return entries[i].vowelSet;
            }
        }
        static const Array2D16 dummy = {nullptr, 0};
        return dummy;
    }
};

// Vowel Combine representation
struct VowelCombineEntry {
    Uint16 key;
    Array2D32 vowelSet;
};

class VowelCombineMap {
public:
    const VowelCombineEntry* entries;
    size_t count;

    Array2D32 operator[](Uint16 key) const {
        for (size_t i = 0; i < count; ++i) {
            if (entries[i].key == key) {
                return entries[i].vowelSet;
            }
        }
        static const Array2D32 dummy = {nullptr, 0};
        return dummy;
    }
};

// Quick Telex map representation
struct QuickTelexEntry {
    Uint32 key;
    Uint16 val[2];
};

class QuickTelexMap {
public:
    const QuickTelexEntry* entries;
    size_t count;

    const Uint16* operator[](Uint32 key) const {
        for (size_t i = 0; i < count; ++i) {
            if (entries[i].key == key) {
                return entries[i].val;
            }
        }
        static const Uint16 dummy[2] = {0, 0};
        return dummy;
    }
};

// Quick Start/End Consonant map representation
struct QuickConsonantEntry {
    Uint16 key;
    Uint16 val[2];
};

class QuickConsonantMap {
public:
    const QuickConsonantEntry* entries;
    size_t count;

    struct const_iterator {
        const QuickConsonantEntry* ptr;
        const QuickConsonantEntry& operator*() const { return *ptr; }
        const QuickConsonantEntry* operator->() const { return ptr; }
        const_iterator& operator++() { ++ptr; return *this; }
        const_iterator operator++(int) { const_iterator tmp = *this; ++ptr; return tmp; }
        bool operator==(const const_iterator& other) const { return ptr == other.ptr; }
        bool operator!=(const const_iterator& other) const { return ptr != other.ptr; }
    };

    const_iterator begin() const { return const_iterator{entries}; }
    const_iterator end() const { return const_iterator{entries + count}; }
    const_iterator find(Uint16 key) const {
        for (size_t i = 0; i < count; ++i) {
            if (entries[i].key == key) {
                return const_iterator{entries + i};
            }
        }
        return end();
    }
    const Uint16* operator[](Uint16 key) const {
        auto it = find(key);
        if (it != end()) return it->val;
        static const Uint16 dummy[2] = {0, 0};
        return dummy;
    }
};

// Character map representation
class CharacterMap {
public:
    struct Entry {
        Uint32 first;
        Uint32 second;
    };

    struct const_iterator {
        const Entry* ptr;
        
        const Entry& operator*() const { return *ptr; }
        const Entry* operator->() const { return ptr; }
        const_iterator& operator++() { ++ptr; return *this; }
        const_iterator operator++(int) { const_iterator tmp = *this; ++ptr; return tmp; }
        bool operator==(const const_iterator& other) const { return ptr == other.ptr; }
        bool operator!=(const const_iterator& other) const { return ptr != other.ptr; }
    };

    const_iterator begin() const;
    const_iterator end() const;
    const_iterator find(Uint32 key) const;
    Uint32 operator[](Uint32 key) const;
};

// Code table representation
struct CodeValues {
    const Uint16* data;
    size_t count;

    size_t size() const { return count; }
    Uint16 operator[](size_t idx) const { return data[idx]; }
};

struct CodeTableEntry {
    Uint32 first;
    CodeValues second;
};

class CodeTable {
public:
    const CodeTableEntry* entries;
    size_t numEntries;

    struct const_iterator {
        const CodeTableEntry* ptr;
        
        const CodeTableEntry& operator*() const { return *ptr; }
        const CodeTableEntry* operator->() const { return ptr; }
        const_iterator& operator++() { ++ptr; return *this; }
        const_iterator operator++(int) { const_iterator tmp = *this; ++ptr; return tmp; }
        bool operator==(const const_iterator& other) const { return ptr == other.ptr; }
        bool operator!=(const const_iterator& other) const { return ptr != other.ptr; }
    };

    typedef const_iterator iterator;

    const_iterator begin() const { return const_iterator{entries}; }
    const_iterator end() const { return const_iterator{entries + numEntries}; }

    const_iterator find(Uint32 key) const {
        for (size_t i = 0; i < numEntries; ++i) {
            if (entries[i].first == key) {
                return const_iterator{entries + i};
            }
        }
        return end();
    }

    CodeValues operator[](Uint32 key) const {
        auto it = find(key);
        if (it != end()) {
            return it->second;
        }
        static const Uint16 dummy[1] = {0};
        return CodeValues{dummy, 0};
    }
};

extern Uint16 douKey[2][2];

extern const VowelMap _vowel;
extern const VowelCombineMap _vowelCombine;
extern const VowelMapEntry _vowelForMarkStatic[6];

extern const Array2D16 _consonantD;
extern const Array2D16 _consonantTable;
extern const Array2D16 _endConsonantTable;
extern const Array16 _standaloneWbad;
extern const Array2D16 _doubleWAllowed;

extern const CodeTable _codeTable[];
extern Uint16 _unicodeCompoundMark[];

extern const QuickTelexMap _quickTelex;
extern const QuickConsonantMap _quickStartConsonant;
extern const QuickConsonantMap _quickEndConsonant;
extern const CharacterMap _characterMap;

extern Uint16 keyCodeToCharacter(const Uint32& keyCode);

#endif /* Vietnamese_h */
