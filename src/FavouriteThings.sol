//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FavouriteThings {
    address immutable OWNER;

    struct Person {
        string name;
        uint256 favoriteNumber;
        string favoriteFood;
        uint256 age;
        string favoriteSport;
    }
    mapping(address => Person) public people;

    constructor() {
        OWNER = msg.sender;
    }

    function addPerson(
        string memory _name,
        uint256 _favoriteNumber,
        string memory _favoriteFood,
        uint256 _age,
        string memory _favoriteSport
    ) external {
        people[msg.sender] = Person({
            name: _name,
            favoriteNumber: _favoriteNumber,
            favoriteFood: _favoriteFood,
            age: _age,
            favoriteSport: _favoriteSport
        });
    }

    function getPerson() public view returns (Person memory) {
        return people[msg.sender];
    }
}
