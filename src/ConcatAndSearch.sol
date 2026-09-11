//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ConcatAndSearch {
    // write a function that concantenates two strings and also a function that locate a word from a sentence and returns the index it was found in the sentence.
    function concatString(string memory str1, string memory str2) external pure returns (string memory) {
        return string(abi.encodePacked(str1, str2));
    }

    function findWord(string memory sentence, string memory word)
        external
        pure
        returns (uint256 index, string memory foundWord)
    {
        bytes memory sentenceBytes = bytes(sentence);
        bytes memory wordBytes = bytes(word);

        if (wordBytes.length == 0) {
            return (type(uint256).max, "");
        }

        if (wordBytes.length > sentenceBytes.length) {
            return (type(uint256).max, "");
        }

        for (uint256 i = 0; i < sentenceBytes.length; i++) {
            // If there aren't enough characters left, stop searching
            if (i + wordBytes.length > sentenceBytes.length) {
                break;
            }

            bool found = true;

            for (uint256 j = 0; j < wordBytes.length; j++) {
                if (sentenceBytes[i + j] != wordBytes[j]) {
                    found = false;
                    break;
                }
            }

            if (found) {
                return (i, word);
            }
        }

        return (type(uint256).max, "");
    }
}
